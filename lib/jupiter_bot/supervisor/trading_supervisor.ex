defmodule JupiterBot.Supervisor.TradingSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Core services
      JupiterBot.Solana.RPCClient,
      {JupiterBot.Solana.WebsocketClient, Application.get_env(:jupiter_bot, :ws_url)},

      # Trading services
      JupiterBot.Jupiter.PerpetualsClient,
      JupiterBot.Trading.RiskManager,

      # Trading strategies
      {JupiterBot.Trading.Strategies.MomentumStrategy, trading_pair: {"SOL", "USDC"}, name: :momentum_strategy},
      {JupiterBot.Trading.Strategies.MovingAverageStrategy, trading_pair: {"SOL", "USDC"}, name: :ma_strategy}
    ]

    # Use rest_for_one to ensure services start in order
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
