defmodule JupiterBot.Trading.PriceHistory do
  @moduledoc """
  Manages historical price data storage and retrieval using ETS tables.
  Supports multiple price sources (Dove Oracle and Pyth) and provides
  interfaces for both real-time price updates and backtesting.
  """
  use GenServer
  require Logger

  @price_table :price_history
  @default_limit 10_000  # Default number of price points to keep

  # Oracle Account addresses from Jupiter docs
  @oracle_accounts %{
    "SOL" => "39cWjvHrpHNz2SbXv6ME4NPhqBDBd4KsjUYv5JkHEAJU",
    "ETH" => "5URYohbPy32nxK1t3jAHVNfdWY2xTubHiFvLrE3VhXEp",
    "BTC" => "4HBbPx9QJdjJ7GUe6bsiJjGybvfpDhQMMPXP1UEa7VT5",
    "USDC" => "A28T5pKtscnhDo6C1Sz786Tup88aTjt8uyKewjVvPrGk",
    "USDT" => "AGW7q2a3WxCzh5TB2Q6yNde1Nf41g3HLaaXdybz7cbBU"
  }

  defmodule PricePoint do
    @moduledoc "Structure for storing individual price points with metadata"
    defstruct [:market, :price, :timestamp, :source, :oracle_account]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS table for storing price history
    :ets.new(@price_table, [:named_table, :ordered_set, :public])

    # Schedule initial oracle data fetch
    schedule_oracle_check()

    {:ok, %{
      markets: %{},
      last_update: nil,
      total_points: 0,
      oracle_accounts: @oracle_accounts
    }}
  end

  @doc """
  Stores a new price point in the history with source attribution.
  """
  def store_price(market, price, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    source = Keyword.get(opts, :source, :realtime)
    oracle_account = Keyword.get(opts, :oracle_account)

    price_point = %PricePoint{
      market: market,
      price: price,
      timestamp: timestamp,
      source: source,
      oracle_account: oracle_account
    }

    :telemetry.execute(
      [:jupiter_bot, :price_history, :store],
      %{price: price},
      %{market: market, source: source}
    )

    GenServer.cast(__MODULE__, {:store_price, price_point})
  end

  @doc """
  Retrieves historical prices for a market within a time range.
  Optionally filter by source.
  """
  def get_price_history(market, from_time, to_time, opts \\ []) do
    source = Keyword.get(opts, :source)

    query_time = DateTime.to_unix(from_time, :microsecond)
    to_time_unix = DateTime.to_unix(to_time, :microsecond)

    match_spec = case source do
      nil ->
        [{{@price_table, market, :"$1", :"$2", :"$3", :_},
          [{:andalso,
            {:>=, :"$1", query_time},
            {:'=<', :"$1", to_time_unix}}],
          [{{:"$2", :"$1", :"$3"}}]}]
      source ->
        [{{@price_table, market, :"$1", :"$2", :"$3", source},
          [{:andalso,
            {:>=, :"$1", query_time},
            {:'=<', :"$1", to_time_unix}}],
          [{{:"$2", :"$1", :"$3"}}]}]
    end

    :ets.select(@price_table, match_spec)
  end

  @doc """
  Returns the latest price for a given market, optionally filtered by source.
  """
  def get_latest_price(market, opts \\ []) do
    source = Keyword.get(opts, :source)

    case source do
      nil -> get_latest_any_source(market)
      source -> get_latest_specific_source(market, source)
    end
  end

  @doc """
  Returns the oracle account address for a given market.
  """
  def get_oracle_account(market) do
    Map.get(@oracle_accounts, market)
  end

  # Server Callbacks

  @impl true
  def handle_cast({:store_price, %PricePoint{} = point}, state) do
    unix_ts = DateTime.to_unix(point.timestamp, :microsecond)
    true = :ets.insert(@price_table, {
      @price_table,
      point.market,
      unix_ts,
      point.price,
      point.source,
      point.oracle_account
    })

    # Cleanup old data if needed
    cleanup_old_data(point.market)

    new_state = state
    |> update_in([Access.key(:total_points)], &(&1 + 1))
    |> put_in([:last_update], point.timestamp)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_oracle_data, state) do
    # Fetch latest prices from oracles
    fetch_oracle_prices()

    # Schedule next check
    schedule_oracle_check()

    {:noreply, state}
  end

  # Private Functions

  defp get_latest_any_source(market) do
    case :ets.match_object(@price_table, {@price_table, market, :_, :_, :_, :_}) do
      [] -> nil
      objects ->
        # Sort by timestamp (descending) and take the first
        objects
        |> Enum.sort_by(fn {_, _, ts, _, _, _} -> ts end, :desc)
        |> List.first()
        |> case do
          {_, _, _, price, _, _} -> price
          _ -> nil
        end
    end
  end

  defp get_latest_specific_source(market, source) do
    case :ets.match_object(@price_table, {@price_table, market, :_, :_, source, :_}) do
      [] -> nil
      objects ->
        # Sort by timestamp (descending) and take the first
        objects
        |> Enum.sort_by(fn {_, _, ts, _, _, _} -> ts end, :desc)
        |> List.first()
        |> case do
          {_, _, _, price, _, _} -> price
          _ -> nil
        end
    end
  end

  defp schedule_oracle_check do
    Process.send_after(self(), :check_oracle_data, 5_000) # Check every 5 seconds
  end

  defp fetch_oracle_prices do
    # TODO: Implement oracle price fetching logic
    # This should connect to both Dove and Pyth oracles
    # For now, we'll just log that we're checking
    Logger.debug("Checking oracle prices")
  end

  defp cleanup_old_data(market) do
    case :ets.info(@price_table, :size) do
      size when size > @default_limit ->
        # Remove oldest entries beyond the limit
        remove_count = size - @default_limit
        {first_key, _} = :ets.first(@price_table)
        delete_oldest(first_key, remove_count)
      _ ->
        :ok
    end
  end

  defp delete_oldest(_, 0), do: :ok
  defp delete_oldest(key, count) do
    :ets.delete(@price_table, key)
    case :ets.next(@price_table, key) do
      :"$end_of_table" -> :ok
      next_key -> delete_oldest(next_key, count - 1)
    end
  end
end
