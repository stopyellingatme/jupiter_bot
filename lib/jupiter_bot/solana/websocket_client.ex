defmodule JupiterBot.Solana.WebsocketClient do
  use WebSockex
  require Logger

  def start_link(_opts) do
    url = "wss://history.oraclesecurity.org/trading-view/stream"
    WebSockex.start_link(url, __MODULE__, %{prices: %{}}, name: __MODULE__)
  end

  def subscribe_to_market(market) do
    WebSockex.cast(__MODULE__, {:subscribe, market})
  end

  def get_latest_price(market) do
    GenServer.call(__MODULE__, {:get_price, market})
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Connected to Oracle Security WebSocket server")
    {:ok, state}
  end

  @impl true
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

  @impl true
  def handle_cast({:subscribe, market}, state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:get_price, market}, _from, state) do
    price = get_in(state, [:prices, market])
    {:reply, {:ok, price}, state}
  end

  defp handle_price_update(%{"a" => "price", "b" => base, "q" => quote, "p" => price_str, "e" => exponent, "t" => timestamp} = data, state) do
    price = String.to_integer(price_str) * :math.pow(10, exponent)
    market = "#{base}-#{quote}"

    new_state = put_in(state, [:prices, market], %{
      price: price,
      timestamp: timestamp
    })

    :telemetry.execute(
      [:jupiter_bot, :perpetuals, :price_fetch],
      %{
        price: price,
        timestamp: timestamp
      },
      %{market: market}
    )

    Phoenix.PubSub.broadcast(
      JupiterBot.PubSub,
      "market_updates",
      {:price_update, market, price, timestamp}
    )

    Logger.debug("Price update for #{market}: #{price}")

    {:ok, new_state}
  end

  defp handle_price_update(data, state) do
    Logger.debug("Unhandled message type: #{inspect(data)}")
    {:ok, state}
  end
end
