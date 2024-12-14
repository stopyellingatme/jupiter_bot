defmodule JupiterBot.Solana.WebsocketState do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{prices: %{}}, name: __MODULE__)
  end

  def get_price(market) do
    GenServer.call(__MODULE__, {:get_price, market})
  end

  def update_price(market, price) do
    GenServer.cast(__MODULE__, {:update_price, market, price})
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:get_price, market}, _from, state) do
    price = get_in(state, [:prices, market])
    {:reply, price, state}
  end

  @impl true
  def handle_cast({:update_price, market, price}, state) do
    new_state = put_in(state, [:prices, market], price)
    {:noreply, new_state}
  end
end
