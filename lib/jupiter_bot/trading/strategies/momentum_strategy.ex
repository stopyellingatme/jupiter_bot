defmodule JupiterBot.Trading.Strategies.MomentumStrategy do
  use GenServer

  @price_check_interval 1_000
  @price_history_limit 500
  @momentum_threshold 0.02

  defmodule State do
    defstruct [
      trading_pair: nil,
      price_history: [],
      current_price: nil,
      current_position: :none,
      momentum_threshold: 0.02,
      total_trades: 0,
      successful_trades: 0,
      current_signal: nil,
      current_momentum: nil,
      exit_threshold: 0.02
    ]
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start_link(strategy_type) when is_atom(strategy_type) do
    # Convert atom to default options
    opts = [
      trading_pair: "SOL-PERP",
      strategy_type: strategy_type,
      interval: @price_check_interval  # 5 seconds
    ]
    start_link(opts)
  end

  @impl true
  def init(opts) do
    {:ok, %{
      trading_pair: Keyword.get(opts, :trading_pair),
      strategy_type: Keyword.get(opts, :strategy_type),
      interval: Keyword.get(opts, :interval, 5_000)
    }}
  end

  @impl true
  def handle_info(:check_price, state) do
    {base, _quote} = state.trading_pair
    case JupiterBot.Jupiter.PerpetualsClient.get_token_price(base) do
      {:ok, %{"price" => price}} ->
        send(self(), {:price_updated, price})
      {:error, _reason} ->
        :telemetry.execute(
          [:jupiter_bot, :strategy, :error],
          %{},
          %{
            trading_pair: format_pair(state.trading_pair),
            error: "Failed to fetch price"
          }
        )
    end

    Process.send_after(self(), :check_price, @price_check_interval)
    {:noreply, state}
  end

  def handle_info({:price_updated, price}, state) do
    new_state = state
                |> Map.put(:current_price, price)
                |> update_price_history()
                |> calculate_momentum()
                |> generate_signals()
                |> execute_trades()

    {base, quote} = new_state.trading_pair
    :telemetry.execute(
      [:jupiter_bot, :strategy, :status_update],
      %{
        price: new_state.current_price,
        momentum: new_state.current_momentum || 0.0
      },
      %{
        pair: "#{base}/#{quote}",
        position: new_state.current_position
      }
    )

    {:noreply, new_state}
  end

  def calculate_momentum(%State{price_history: history} = state) when length(history) > 1 do
    [current | [previous | _]] = history

    momentum = case {current.price, previous.price} do
      {current_price, previous_price} when is_number(current_price) and is_number(previous_price) and previous_price != 0 ->
        (current_price - previous_price) / previous_price
      _ -> 0.0
    end

    if state.trading_pair do
      :telemetry.execute(
        [:jupiter_bot, :strategy, :momentum_update],
        %{momentum: momentum},
        %{
          pair: format_pair(state.trading_pair),
          position: state.current_position
        }
      )
    end

    %{state | current_momentum: momentum}
  end
  def calculate_momentum(state), do: %{state | current_momentum: 0.0}

  def generate_signals(%State{current_momentum: momentum, momentum_threshold: threshold} = state) do
    signal = cond do
      momentum > threshold -> :long
      momentum < -threshold -> :short
      true -> :none
    end
    Map.put(state, :current_signal, signal)
  end

  def trade_management(%State{current_position: position, current_momentum: momentum, exit_threshold: threshold} = state) do
    case {position, momentum} do
      {:long, momentum} when momentum < -threshold ->
        %{state | current_position: :none}
      {:short, momentum} when momentum > threshold ->
        %{state | current_position: :none}
      _ ->
        state
    end
  end

  defp execute_trades(%State{current_signal: signal, current_position: position} = state) do
    {new_position, state} = case {position, signal} do
      {:none, :buy} ->
        :telemetry.execute(
          [:jupiter_bot, :strategy, :trade_signal],
          %{
            signal: :buy,
            price: state.current_price,
            new_position: :long
          },
          %{
            trading_pair: format_pair(state.trading_pair),
            current_position: position
          }
        )
        {:long, update_trade_stats(state, :success)}
      {:none, :sell} ->
        :telemetry.execute(
          [:jupiter_bot, :strategy, :trade_signal],
          %{
            signal: :sell,
            price: state.current_price,
            new_position: :short
          },
          %{
            trading_pair: format_pair(state.trading_pair),
            current_position: position
          }
        )
        {:short, update_trade_stats(state, :success)}
      {:long, :sell} ->
        log_trade_signal("Closing LONG position", state)
        {:none, update_trade_stats(state, :success)}
      {:short, :buy} ->
        log_trade_signal("Closing SHORT position", state)
        {:none, update_trade_stats(state, :success)}
      _ ->
        {position, state}
    end
    %{state | current_position: new_position}
  end

  defp update_price_history(%State{price_history: history} = state) do
    new_history = [
      %{price: state.current_price, timestamp: DateTime.utc_now()}
      | history
    ] |> Enum.take(@price_history_limit)

    %{state | price_history: new_history}
  end

  defp log_trade_signal(message, %State{trading_pair: {base, quote}, current_price: price}) do
    Logger.info("""
     Trade Signal Generated
    ------------------------
    Pair: #{base}/#{quote}
    Action: #{message}
    Price: #{format_price(price)}
    Time: #{DateTime.utc_now() |> DateTime.to_string()}
    """)
  end

  defp log_strategy_status(state) do
    %{
      trading_pair: {base, quote},
      current_price: price,
      current_momentum: momentum,
      current_position: position,
      strategy_stats: stats
    } = state

    Logger.info("""
    📊 Strategy Status Update
    ------------------------
    Pair: #{base}/#{quote}
    Price: #{format_price(price)}
    Momentum: #{format_percentage(momentum)}
    Position: #{position}
    Total Trades: #{stats.total_trades}
    Success Rate: #{format_percentage(stats.successful_trades / max(stats.total_trades, 1))}
    """)

    state
  end

  defp update_trade_stats(state, :success) do
    update_in(state.strategy_stats, fn stats ->
      %{stats |
        total_trades: stats.total_trades + 1,
        successful_trades: stats.successful_trades + 1
      }
    end)
  end

  defp format_strategy_stats(state) do
    %{
      trading_pair: {base, quote},
      current_position: position,
      strategy_stats: stats
    } = state

    %{
      trading_pair: "#{base}/#{quote}",
      position: position,
      total_trades: stats.total_trades,
      successful_trades: stats.successful_trades,
      success_rate: format_percentage(stats.successful_trades / max(stats.total_trades, 1)),
      running_since: stats.start_time |> DateTime.to_string()
    }
  end

  defp format_price(price) when is_number(price), do: :erlang.float_to_binary(price, decimals: 4)
  defp format_price(_), do: "N/A"

  defp format_percentage(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  end
  defp format_percentage(_), do: "N/A"

  defp format_pair(nil), do: "UNKNOWN/UNKNOWN"
  defp format_pair({base, quote}), do: "#{base}/#{quote}"

  defp calculate_success_rate(%State{total_trades: 0}), do: 0.0
  defp calculate_success_rate(%State{total_trades: total, successful_trades: successful}) do
    successful / total * 100
  end
end
