defmodule JupiterBot.Telemetry.Metrics do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = :telemetry.attach_many(
      "jupiter-bot-metrics",
      [
        [:jupiter_bot, :strategy, :price_update],
        [:jupiter_bot, :perpetuals, :price_fetch],
        [:jupiter_bot, :perpetuals, :swap_quote],
        [:jupiter_bot, :strategy, :trade_signal],
        [:jupiter_bot, :strategy, :momentum_update]
      ],
      &handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  # Price update events
  def handle_event([:jupiter_bot, :strategy, :price_update], measurements, metadata, _config) do
    message = """
    💰 Price Update
    --------------
    Pair: #{metadata.pair}
    Price: #{Float.round(measurements.price, 4)}
    Time: #{DateTime.utc_now()}
    """
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter, {:debug_log, message})
  end

  # Perpetuals price fetch events
  def handle_event([:jupiter_bot, :perpetuals, :price_fetch], measurements, metadata, _config) do
    Logger.info("""
    📊 Perpetuals Price
    ------------------
    Token: #{metadata.token}
    Price: #{Float.round(measurements.price, 4)}
    Confidence: #{Float.round(measurements.confidence * 100, 2)}%
    """)
  end

  # Swap quote events
  def handle_event([:jupiter_bot, :perpetuals, :swap_quote], measurements, metadata, _config) do
    Logger.info("""
    🔄 Swap Quote
    ------------
    From: #{metadata.from_token}
    To: #{metadata.to_token}
    Amount: #{measurements.input_amount}
    Quote: #{measurements.output_amount}
    Price Impact: #{format_percentage(measurements.price_impact)}
    """)
  end

  # Trade signal events
  def handle_event([:jupiter_bot, :strategy, :trade_signal], measurements, metadata, _config) do
    Logger.info("""
    🎯 Trade Signal
    --------------
    Pair: #{metadata.trading_pair}
    Signal: #{measurements.signal}
    Price: #{format_price(measurements.price)}
    Position: #{metadata.current_position} -> #{measurements.new_position}
    """)
  end

  # Momentum update events
  def handle_event([:jupiter_bot, :strategy, :momentum_update], measurements, metadata, _config) do
    Logger.info("""
    📈 Momentum Update
    ----------------
    Pair: #{metadata.pair}
    Momentum: #{Float.round(measurements.momentum * 100, 2)}%
    Threshold: #{Float.round(0.02 * 100, 2)}%
    Current Position: #{metadata[:position] || "none"}
    """)
  end

  # Helper functions
  defp format_price(price) when is_number(price) do
    :erlang.float_to_binary(price, decimals: 4)
  end
  defp format_price(_), do: "N/A"

  defp format_percentage(value) when is_number(value) do
    "#{:erlang.float_to_binary(value * 100, decimals: 2)}%"
  end
  defp format_percentage(_), do: "N/A"
end
