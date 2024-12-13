defmodule JupiterBot.Trading.Strategies.MomentumStrategyTest do
  use ExUnit.Case
  alias JupiterBot.Trading.Strategies.MomentumStrategy
  alias JupiterBot.Trading.Strategies.MomentumStrategy.State

  describe "calculate_momentum/1" do
    test "calculates positive momentum correctly" do
      state = %State{
        price_history: [
          %{price: 110.0, timestamp: DateTime.utc_now()},
          %{price: 100.0, timestamp: DateTime.utc_now()}
        ]
      }

      result = MomentumStrategy.calculate_momentum(state)
      assert_in_delta result.current_momentum, 0.10, 0.001  # 10% increase
    end

    test "calculates negative momentum correctly" do
      state = %State{
        price_history: [
          %{price: 90.0, timestamp: DateTime.utc_now()},
          %{price: 100.0, timestamp: DateTime.utc_now()}
        ]
      }

      result = MomentumStrategy.calculate_momentum(state)
      assert_in_delta result.current_momentum, -0.10, 0.001  # 10% decrease
    end

    test "returns zero momentum with insufficient price history" do
      state = %State{
        price_history: [
          %{price: 100.0, timestamp: DateTime.utc_now()}
        ]
      }

      result = MomentumStrategy.calculate_momentum(state)
      assert result.current_momentum == 0.0
    end
  end

  describe "generate_signals/1" do
    test "generates long signal when momentum exceeds threshold" do
      state = %State{
        current_momentum: 0.05,  # 5% positive momentum
        momentum_threshold: 0.03
      }

      result = MomentumStrategy.generate_signals(state)
      assert result.current_signal == :long
    end

    test "generates short signal when momentum below negative threshold" do
      state = %State{
        current_momentum: -0.05,  # 5% negative momentum
        momentum_threshold: 0.03
      }

      result = MomentumStrategy.generate_signals(state)
      assert result.current_signal == :short
    end

    test "generates no signal when momentum within threshold" do
      state = %State{
        current_momentum: 0.02,  # 2% momentum
        momentum_threshold: 0.03
      }

      result = MomentumStrategy.generate_signals(state)
      assert result.current_signal == :none
    end
  end

  describe "trade_management/1" do
    test "closes long position when momentum turns negative" do
      state = %State{
        current_position: :long,
        current_momentum: -0.02,
        exit_threshold: 0.01
      }

      result = MomentumStrategy.trade_management(state)
      assert result.current_position == :none
    end

    test "closes short position when momentum turns positive" do
      state = %State{
        current_position: :short,
        current_momentum: 0.02,
        exit_threshold: 0.01
      }

      result = MomentumStrategy.trade_management(state)
      assert result.current_position == :none
    end

    test "maintains position when momentum favorable" do
      state = %State{
        current_position: :long,
        current_momentum: 0.03,
        exit_threshold: 0.01
      }

      result = MomentumStrategy.trade_management(state)
      assert result.current_position == :long
    end
  end
end
