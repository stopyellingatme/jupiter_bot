defmodule JupiterBot.Solana.WebsocketClient do
  use WebSockex
  require Logger
  alias JupiterBot.Solana.WebsocketState

  def start_link(_opts) do
    url = "wss://history.oraclesecurity.org/trading-view/stream"
    WebSockex.start_link(url, __MODULE__, %{}, name: __MODULE__)
  end

  def subscribe_to_market(market) do
    WebSockex.cast(__MODULE__, {:subscribe, market})
  end

  def get_latest_price(market) do
    WebsocketState.get_price(market)
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "🟢 Connected to Oracle Security WebSocket server"})
    :telemetry.execute([:jupiter_bot, :rpc, :connect], %{}, %{type: :websocket})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data = %{"a" => "price"}} ->
        handle_price_update(data, state)
      {:ok, other_data} ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "⚪ Other data: #{inspect(other_data)}"}
        )
        {:ok, state}
      {:error, reason} ->
        GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
          {:debug_log, "🔴 Error: #{inspect(reason)}"}
        )
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_cast({:subscribe, _market}, state) do
    # Implementation for subscription
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "🔴 WebSocket Disconnected: #{inspect(reason)}"})
    {:ok, state}
  end

  @impl WebSockex
  def terminate(reason, _state) do
    GenServer.cast(JupiterBot.Telemetry.ConsoleReporter,
      {:debug_log, "🔴 WebSocket terminating: #{inspect(reason)}"})
    exit(:normal)
  end

  defp handle_price_update(%{
    "a" => "price",
    "b" => base,
    "q" => quote,
    "p" => price_str,
    "e" => _exponent,
    "t" => _timestamp
  } = _data, state) do
    # Update price in WebsocketState
    WebsocketState.update_price("#{base}-#{quote}", price_str)
    {:ok, state}
  end
end
