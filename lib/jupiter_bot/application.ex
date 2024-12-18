defmodule JupiterBot.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the PubSub system
      {Phoenix.PubSub, name: JupiterBot.PubSub},
      # Start Finch for HTTP requests
      {Finch, name: JupiterBot.HTTP},
      # Start the Telemetry supervisor
      JupiterBot.Telemetry.ConsoleReporter,
      # Start the Trading supervisor
      JupiterBot.Supervisor.TradingSupervisor,
      {JupiterBot.Trading.PriceHistory, []},
    ]

    opts = [strategy: :one_for_one, name: JupiterBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
