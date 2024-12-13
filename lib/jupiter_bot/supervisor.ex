defmodule JupiterBot.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Strategy Supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: JupiterBot.Supervisor.StrategySupervisor},

      # Core Services
      {JupiterBot.Trading.PositionManager, []},
      {JupiterBot.Trading.RiskManager, []},
      {JupiterBot.Solana.RPCClient, []},
      {JupiterBot.Solana.WebsocketClient, []},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
