defmodule JupiterBot do
  @moduledoc """
  JupiterBot is a trading bot for Jupiter perpetuals on Solana.
  This module provides the main public API for interacting with the trading system.
  """

  alias JupiterBot.Trading.{PositionManager, RiskManager}
  alias JupiterBot.Solana.{RPCClient, WebsocketClient}

  @doc """
  Opens a new trading position.

  ## Parameters
    * pair - Trading pair (e.g., "SOL-PERP")
    * size - Position size in USD
    * leverage - Leverage multiplier
    * direction - :long or :short

  ## Examples
      iex> {:ok, %{position_id: _}} = JupiterBot.open_position("SOL-PERP", 100, 2, :long)
      iex> true
      true
  """
  def open_position(pair, size, leverage, direction) do
    PositionManager.open_position(pair, size, leverage, direction)
  end

  @doc """
  Closes an existing position.

  ## Parameters
    * position_id - The ID of the position to close
    * pid - The process ID of the strategy to close

  ## Examples
      iex> JupiterBot.close_position("position_123")
      {:ok, %{closed_at: "2024-03-20T12:00:00Z"}}

      iex> {:ok, pid} = JupiterBot.start_strategy(:momentum)
      iex> JupiterBot.close_position(pid)
      :ok
  """
  def close_position(position_id) when is_binary(position_id) do
    PositionManager.close_position(position_id)
  end

  def close_position(pid) when is_pid(pid) do
    # Implementation for closing by PID
    GenServer.stop(pid)
  end

  @doc """
  Starts a trading strategy.

  ## Examples

      iex> {:ok, pid} = JupiterBot.start_strategy(:momentum)
      iex> is_pid(pid)
      true
  """
  def start_strategy(strategy_type) do
    DynamicSupervisor.start_child(
      JupiterBot.Supervisor.StrategySupervisor,
      {JupiterBot.Trading.Strategies.MomentumStrategy, strategy_type}
    )
  end

  @doc """
  Gets the current account balance.

  ## Examples
      iex> JupiterBot.get_balance()
      {:ok, %{total_usd: 1000.00, available_usd: 800.00}}
  """
  def get_balance do
    RPCClient.get_account_info(config(:wallet_pubkey))
  end

  @doc """
  Subscribes to market updates for a specific trading pair.

  ## Parameters
    * pair - Trading pair to subscribe to

  ## Examples
      iex> JupiterBot.subscribe_to_market("SOL-PERP")
      :ok
  """
  def subscribe_to_market(pair) do
    WebsocketClient.subscribe_to_market(pair)
  end

  @doc """
  Gets the current risk metrics for the trading system.

  ## Examples
      iex> JupiterBot.risk_metrics()
      {:ok, %{drawdown: 5.2, exposure: 0.3}}
  """
  def risk_metrics do
    RiskManager.get_metrics()
  end

  @doc """
  Helper function to get configuration values.
  """
  def config(key) do
    Application.get_env(:jupiter_bot, key)
  end
end
