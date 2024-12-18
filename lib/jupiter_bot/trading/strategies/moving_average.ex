defmodule JupiterBot.Trading.Strategies.MovingAverage do
  @moduledoc """
  Core Moving Average calculations and signal generation.
  This module handles the mathematical and analytical components.
  """

  # MA Periods for multiple timeframe analysis
  @short_period 9    # Quick response to price changes
  @medium_period 21  # Trend confirmation
  @long_period 50    # Overall trend direction

  # Signal thresholds
  @trend_strength_threshold 0.02  # 2% minimum trend strength
  @momentum_threshold 0.01        # 1% minimum momentum

  @type ma_data :: %{
    price: float(),
    short_ma: float() | nil,
    medium_ma: float() | nil,
    long_ma: float() | nil,
    trend_strength: float(),
    momentum: float()
  }

  @doc """
  Calculates multiple moving averages and trend indicators from price data.
  Returns progressively more complete data as more prices become available.
  """
  @spec calculate_indicators([number()]) :: ma_data() | nil
  def calculate_indicators(prices) when length(prices) > 0 do
    current_price = hd(prices)

    # Calculate each MA if we have enough data
    {short_ma, short_ready} = calculate_single_ma(prices, @short_period)
    {medium_ma, _medium_ready} = calculate_single_ma(prices, @medium_period)
    {long_ma, _long_ready} = calculate_single_ma(prices, @long_period)

    if short_ready do
      trend_strength = calculate_trend_strength(short_ma, medium_ma, long_ma)
      momentum = calculate_momentum(Enum.take(prices, @short_period))

      %{
        price: current_price,
        short_ma: short_ma,
        medium_ma: medium_ma,
        long_ma: long_ma,
        trend_strength: trend_strength,
        momentum: momentum
      }
    else
      nil
    end
  end
  def calculate_indicators(_), do: nil

  # Calculates a single moving average value for the given period.
  # Returns {value, ready} tuple where ready indicates if enough data was available.
  defp calculate_single_ma(prices, period) when is_list(prices) and length(prices) >= period do
    case Enum.take(prices, period) do
      [] -> {nil, false}
      values ->
        # Ensure we have valid numbers before calculation
        if Enum.any?(values, &is_nil/1) do
          {nil, false}
        else
          {Enum.sum(values) / period, true}
        end
    end
  end
  defp calculate_single_ma(_, _), do: {nil, false}

  defp calculate_trend_strength(short_ma, medium_ma, long_ma) when not is_nil(short_ma) do
    cond do
      not is_nil(medium_ma) and not is_nil(long_ma) ->
        short_medium_diff = abs(short_ma - medium_ma) / medium_ma
        medium_long_diff = abs(medium_ma - long_ma) / long_ma
        (short_medium_diff + medium_long_diff) / 2

      not is_nil(medium_ma) ->
        abs(short_ma - medium_ma) / medium_ma

      true -> 0.0
    end
  end
  defp calculate_trend_strength(_, _, _), do: 0.0

  defp calculate_momentum(prices) when length(prices) > 0 do
    current = hd(prices)
    avg = calculate_ma(prices)
    (current - avg) / avg
  end
  defp calculate_momentum(_), do: 0.0

  defp calculate_ma(prices) when length(prices) > 0 do
    Enum.sum(prices) / length(prices)
  end

  @doc """
  Generates trading signals based on available MA data.
  Signal strength increases as more indicators become available.
  """
  @spec generate_signal(ma_data()) :: {:long | :short | :none, float()}
  def generate_signal(%{
    price: price,
    short_ma: short_ma,
    medium_ma: medium_ma,
    long_ma: long_ma,
    trend_strength: strength,
    momentum: momentum
  }) when not is_nil(short_ma) do
    signal = cond do
      # Full signal with all MAs
      not is_nil(medium_ma) and not is_nil(long_ma) ->
        cond do
          short_ma > medium_ma and medium_ma > long_ma and
          strength > @trend_strength_threshold and
          momentum > @momentum_threshold -> :long

          short_ma < medium_ma and medium_ma < long_ma and
          strength > @trend_strength_threshold and
          momentum < -@momentum_threshold -> :short

          true -> :none
        end

      # Partial signal with just short and medium MAs
      not is_nil(medium_ma) ->
        cond do
          short_ma > medium_ma and momentum > @momentum_threshold -> :long
          short_ma < medium_ma and momentum < -@momentum_threshold -> :short
          true -> :none
        end

      # Basic signal with just short MA
      true ->
        cond do
          price > short_ma and momentum > @momentum_threshold -> :long
          price < short_ma and momentum < -@momentum_threshold -> :short
          true -> :none
        end
    end

    {signal, strength}
  end
  def generate_signal(_), do: {:none, 0.0}
end
