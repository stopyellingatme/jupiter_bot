defmodule JupiterBot.Trading.Strategies.MovingAverageStrategyTest do
  use ExUnit.Case
  alias JupiterBot.Trading.Strategies.MovingAverageStrategy
  alias JupiterBot.Trading.Strategies.MovingAverageStrategy.State

  # Helper to create price history entries
  defp create_price_history(prices) do
    prices
    |> Enum.map(fn price ->
      %{price: price, timestamp: DateTime.utc_now()}
    end)
  end

  describe "calculate_moving_averages/1" do
    test "calculates both MAs when enough data points exist" do
      # Create test data: 30 prices from 100 to 129
      prices = Enum.to_list(100..129)
      state = %State{
        price_history: create_price_history(prices)
      }

      result = MovingAverageStrategy.calculate_moving_averages(state)

      # Short MA (10 periods) should be average of last 10 prices (120-129)
      assert_in_delta result.short_ma, 124.5, 0.01
      # Long MA (30 periods) should be average of all 30 prices (100-129)
      assert_in_delta result.long_ma, 114.5, 0.01
    end

    test "returns nil for MAs when insufficient data" do
      state = %State{
        price_history: create_price_history([100, 101, 102])
      }

      result = MovingAverageStrategy.calculate_moving_averages(state)
      assert is_nil(result.short_ma)
      assert is_nil(result.long_ma)
    end
  end

  describe "generate_signals/1" do
    test "generates long signal when short MA crosses above long MA" do
      state = %State{
        short_ma: 120.0,
        long_ma: 115.0
      }

      result = MovingAverageStrategy.generate_signals(state)
      assert result.current_signal == :long
    end

    test "generates short signal when short MA crosses below long MA" do
      state = %State{
        short_ma: 115.0,
        long_ma: 120.0
      }

      result = MovingAverageStrategy.generate_signals(state)
      assert result.current_signal == :short
    end

    test "generates no signal when MAs are equal" do
      state = %State{
        short_ma: 120.0,
        long_ma: 120.0
      }

      result = MovingAverageStrategy.generate_signals(state)
      assert result.current_signal == :none
    end
  end

  describe "execute_trades/1" do
    test "enters long position when signal is long and no current position" do
      state = %State{
        current_signal: :long,
        current_position: :none
      }

      result = MovingAverageStrategy.execute_trades(state)
      assert result.current_position == :long
    end

    test "enters short position when signal is short and no current position" do
      state = %State{
        current_signal: :short,
        current_position: :none
      }

      result = MovingAverageStrategy.execute_trades(state)
      assert result.current_position == :short
    end

    test "maintains existing position when signal matches position" do
      state = %State{
        current_signal: :long,
        current_position: :long
      }

      result = MovingAverageStrategy.execute_trades(state)
      assert result.current_position == :long
    end
  end
end
