# JupiterBot

JupiterBot is an automated trading bot for Jupiter perpetuals on Solana, built with Elixir. It provides real-time market analysis, multiple trading strategies, and a console-based monitoring interface.

## Features

- Real-time price monitoring via WebSocket connection
- Multiple trading strategies:
  - Moving Average (MA) crossover strategy
  - Momentum-based trading
  - Simple Moving Average (SMA) strategy
- Live trading statistics and visualization
- Risk management system
- Telemetry and performance monitoring
- Persistent state management
- Fault-tolerant architecture

## Architecture

The system is built using a supervision tree with the following main components:

- Trading Supervisor
- WebSocket Client for real-time data
- Strategy Managers
- Telemetry and Metrics
- Console Reporter for live monitoring

## Installation

1. Ensure you have Elixir installed on your system
2. Add `jupiter_bot` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jupiter_bot, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/jupiter_bot>.

