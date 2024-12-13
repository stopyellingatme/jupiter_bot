defmodule JupiterBot.Trading.RiskManager do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = %{drawdown: 5.2, exposure: 0.3}
    {:reply, {:ok, metrics}, state}
  end
end
