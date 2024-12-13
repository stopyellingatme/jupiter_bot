defmodule JupiterBot.Trading.Strategy do
  @type order :: %{
    pair: String.t(),
    size: number(),
    direction: :long | :short,
    type: :market | :limit,
    price: number() | nil
  }

  @callback name() :: String.t()
  @callback init(map()) :: {:ok, map()}
  @callback handle_tick(map(), map()) :: {:ok, list(order()), map()}

  defmodule Base do
    defstruct [:name, :state, :config]
  end

  defmodule SimpleMovingAverage do
    @behaviour JupiterBot.Trading.Strategy

    def name(), do: "SMA Crossover"

    def init(config) do
      {:ok, %{
        short_period: config.short_period || 10,
        long_period: config.long_period || 20,
        prices: [],
        position: nil
      }}
    end

    def handle_tick(price_data, state) do
      new_prices = [price_data.price | state.prices] |> Enum.take(state.long_period)

      with {:ok, short_sma} <- calculate_sma(new_prices, state.short_period),
           {:ok, long_sma} <- calculate_sma(new_prices, state.long_period) do

        orders = generate_orders(short_sma, long_sma, state.position)
        new_state = %{state | prices: new_prices}

        {:ok, orders, new_state}
      end
    end

    defp calculate_sma(prices, period) do
      case length(prices) >= period do
        true ->
          avg = prices
          |> Enum.take(period)
          |> Enum.sum()
          |> Kernel./(period)
          {:ok, avg}
        false ->
          {:error, :insufficient_data}
      end
    end

    defp generate_orders(_short_sma, _long_sma, _current_position) do
      # Strategy-specific order generation logic
      []
    end
  end

  def start_strategy(strategy_module, config) do
    DynamicSupervisor.start_child(
      JupiterBot.Trading.StrategySupervisor,
      {strategy_module, config}
    )
  end
end
