defmodule JupiterBot.Trading.Strategies.MovingAverageStrategy do
  use GenServer, restart: :permanent
  alias JupiterBot.Trading.Strategies.MovingAverage

  @price_check_interval 1000
  @price_history_limit 500
  @min_price_change 0.00001  # Reduced to 0.001% to allow more price updates
  @storage_key :ma_strategy_state
  @strategy_name {:global, :ma_strategy}

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

    case :global.whereis_name(:ma_strategy) do
      :undefined ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Starting new MA Strategy instance"})
        GenServer.start_link(__MODULE__, trading_pair, [name: @strategy_name] ++ opts)
      pid ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "MA Strategy already running with PID: #{inspect(pid)}"})
        {:ok, pid}
    end
  end

  @impl true
  def init(trading_pair) do
    Process.flag(:trap_exit, true)

    # Try to recover state from persistent storage
    initial_state = case :persistent_term.get(@storage_key, nil) do
      nil ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Initializing new MA Strategy for #{inspect(trading_pair)}"})
        %State{
          trading_pair: trading_pair,
          price_history: [],
          last_update: DateTime.utc_now()
        }
      saved_state ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Recovered MA Strategy with #{length(saved_state.price_history)} prices"})
        saved_state
    end

    # Always start price checks
    send(self(), :check_price)

    {:ok, initial_state}
  end

  @impl true
  def terminate(reason, state) do
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "MA Strategy terminating - Reason: #{inspect(reason)}"})
    :persistent_term.put(@storage_key, state)
    :ok
  end

  @impl true
  def handle_info(:check_price, state) do
    {base, _quote} = state.trading_pair

    # Schedule next check first
    Process.send_after(self(), :check_price, @price_check_interval)

    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "Checking price for #{base}"})

    # Fetch new price
    case JupiterBot.Jupiter.PerpetualsClient.get_token_price(base) do
      {:ok, %{"price" => price}} ->
        send(self(), {:price_updated, price})
      {:error, reason} ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Price fetch failed: #{inspect(reason)}"})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:price_updated, price}, %State{price_history: history} = state) do
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "Processing price update: #{price}"})

    timestamp = DateTime.utc_now()
    new_price_point = %PricePoint{price: price, timestamp: timestamp}

    # Ensure history is always a list
    current_history = history || []

    # Only add new price if it's significantly different from the last price
    new_history = case current_history do
      [last | _] when abs(last.price - price) < @min_price_change ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Skipping similar price: #{price} vs #{last.price} (keeping #{length(current_history)} prices)"})
        current_history
      _ ->
        updated_history = [new_price_point | current_history] |> Enum.take(@price_history_limit)
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "Added new price: #{price} (history size: #{length(updated_history)})"})
        updated_history
    end

    new_state = %State{state |
      current_price: price,
      price_history: new_history,
      last_update: timestamp
    }

    new_state
    |> update_indicators()
    |> generate_signals()
    |> execute_trades()
    |> report_status()

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:process_history, history}, state) when length(history) > 0 do
    prices = Enum.map(history, & &1.price)
    current_price = List.first(prices)

    add_debug_log("Processing #{length(prices)} prices from history")

    timestamp = DateTime.utc_now()
    price_points = Enum.map(history, fn price ->
      %PricePoint{price: price, timestamp: timestamp}
    end)

    new_state = %{state |
      current_price: current_price,
      price_history: price_points,
      last_update: timestamp
    }
    |> update_indicators()
    |> generate_signals()
    |> execute_trades()

    report_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:process_history, _}, state) do
    {:noreply, state}
  end

  defp update_indicators(%State{} = state) do
    prices = Enum.map(state.price_history, & &1.price)

    case MovingAverage.calculate_indicators(prices) do
      nil ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "MA calculation failed with #{length(prices)} prices"})
        state
      ma_data ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "MA calculation success - Short: #{ma_data.short_ma}"})
        %{state | ma_data: ma_data}
    end
  end

  defp generate_signals(%State{ma_data: ma_data} = state) when not is_nil(ma_data) do
    {signal, strength} = MovingAverage.generate_signal(ma_data)
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "Generated signal: #{signal} with strength: #{strength}"})
    %{state | current_signal: signal, last_signal_strength: strength}
  end
  defp generate_signals(state) do
    add_debug_log("No MA data available for signal generation")
    state
  end

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
