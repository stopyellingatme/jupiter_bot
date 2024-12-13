defmodule JupiterBot.Trading.Strategies.MovingAverageStrategy do
  use GenServer
  alias JupiterBot.Trading.Strategies.MovingAverage
  alias JupiterBot.Telemetry.ConsoleReporter

  @price_check_interval 1000
  @price_history_limit 500  # Increased for better historical analysis
  @min_price_change 0.0001  # Minimum price change to record (0.01%)

  defmodule PricePoint do
    defstruct [:price, :timestamp]
  end

  defmodule State do
    defstruct [
      trading_pair: nil,
      price_history: [],     # List of PricePoint structs
      current_price: nil,
      current_position: :none,
      ma_data: nil,
      total_trades: 0,
      successful_trades: 0,
      current_signal: nil,
      last_signal_strength: 0.0,
      last_update: nil
    ]
  end

  def start_link(opts) do
    {trading_pair, opts} = Keyword.pop(opts, :trading_pair)
    GenServer.start_link(__MODULE__, trading_pair, opts)
  end

  @impl true
  def init(trading_pair) do
    send(self(), :check_price)
    {:ok, %State{trading_pair: trading_pair}}
  end

  @impl true
  def handle_info(:check_price, state) do
    {base, _quote} = state.trading_pair

    # Fetch new price
    case JupiterBot.Jupiter.PerpetualsClient.get_token_price(base) do
      {:ok, %{"price" => price}} ->
        # Emit telemetry event for ConsoleReporter
        :telemetry.execute(
          [:jupiter_bot, :perpetuals, :price_fetch],
          %{price: price, timestamp: DateTime.utc_now()},
          %{market: "#{base}-USDC"}
        )

        # Process the new price directly
        send(self(), {:price_updated, price})

      {:error, reason} ->
        add_debug_log("Failed to fetch price: #{inspect(reason)}")
    end

    Process.send_after(self(), :check_price, @price_check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:process_history, history}, state) when length(history) > 0 do
    prices = Enum.map(history, & &1.price)
    current_price = List.first(prices)

    add_debug_log("Processing #{length(prices)} prices from history")

    new_state = %{state | current_price: current_price}
    |> update_indicators(prices)
    |> generate_signals()
    |> execute_trades()

    report_status(new_state)
    {:noreply, new_state}
  end
  def handle_info({:process_history, _}, state) do
    {:noreply, state}
  end

  defp update_indicators(%State{} = state, prices) when length(prices) > 0 do
    case MovingAverage.calculate_indicators(prices) do
      nil ->
        add_debug_log("Not enough data for MA calculations")
        state
      ma_data ->
        %{state | ma_data: ma_data}
    end
  end
  defp update_indicators(state, _), do: state

  defp generate_signals(%State{ma_data: ma_data} = state) when not is_nil(ma_data) do
    {signal, strength} = MovingAverage.generate_signal(ma_data)
    %{state | current_signal: signal, last_signal_strength: strength}
  end
  defp generate_signals(state), do: state

  defp execute_trades(%State{current_signal: signal, current_position: position} = state) do
    case {position, signal} do
      {:none, :long} -> %{state | current_position: :long}
      {:none, :short} -> %{state | current_position: :short}
      {:long, :short} -> %{state | current_position: :none}
      {:short, :long} -> %{state | current_position: :none}
      _ -> state
    end
  end

  defp report_status(state) do
    :telemetry.execute(
      [:jupiter_bot, :strategy, :status_update],
      %{
        price: state.current_price,
        signal_strength: state.last_signal_strength,
        ma_data: state.ma_data || %{
          short_ma: nil,
          medium_ma: nil,
          long_ma: nil,
          momentum: 0.0,
          trend_strength: 0.0
        }
      },
      %{
        strategy: "MA",
        trading_pair: state.trading_pair,
        position: state.current_position,
        signal: state.current_signal
      }
    )
  end

  defp add_debug_log(message) do
    timestamp = DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
    Process.put(:debug_logs, ["#{timestamp} | Strategy: #{message}" | Process.get(:debug_logs, [])])
  end

  @impl true
  def handle_info({:price_updated, price}, state) do
    new_history = [price | state.price_history] |> Enum.take(@price_history_limit)

    new_state = %{state |
      current_price: price,
      price_history: new_history
    }
    |> update_indicators(new_history)
    |> generate_signals()
    |> execute_trades()

    report_status(new_state)
    {:noreply, new_state}
  end

  # Add helper functions for price history analysis
  def get_price_history_stats(price_history) do
    prices = Enum.map(price_history, & &1.price)

    %{
      count: length(prices),
      max_price: if(length(prices) > 0, do: Enum.max(prices), else: nil),
      min_price: if(length(prices) > 0, do: Enum.min(prices), else: nil),
      avg_price: if(length(prices) > 0, do: Enum.sum(prices) / length(prices), else: nil),
      time_span: calculate_time_span(price_history)
    }
  end

  defp calculate_time_span([]), do: 0
  defp calculate_time_span([latest | _] = history) do
    case List.last(history) do
      nil -> 0
      oldest ->
        DateTime.diff(latest.timestamp, oldest.timestamp, :second)
    end
  end
end
