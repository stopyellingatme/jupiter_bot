defmodule JupiterBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :jupiter_bot,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {JupiterBot.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:finch, "~> 0.16"},
      {:websockex, "~> 0.4.3"},
      {:decimal, "~> 2.0"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:solana, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:tesla, "~> 1.4.0"},
      {:hackney, "~> 1.18"}
    ]
  end
end
