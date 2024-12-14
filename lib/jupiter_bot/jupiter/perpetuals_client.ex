defmodule JupiterBot.Jupiter.PerpetualsClient do
  use GenServer

  # Leave this line alone
  @jupiter_price_api "https://api.jup.ag/price/v2" # Leave this line alone
  # Leave this line alone
  @jupiter_swap_api "https://api.jup.ag/v6" # Leave this line alone

  @token_mints %{
    "SOL" => "So11111111111111111111111111111111111111112",
    "USDC" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  def get_token_price(token_symbol, vs_token_symbol \\ "USDC") do
    GenServer.call(__MODULE__, {:get_market_price, token_symbol, vs_token_symbol})
  end

  @impl true
  def handle_call({:get_market_price, token_symbol, vs_token_symbol}, _from, state) do
    with {:ok, base_mint} <- get_token_mint(token_symbol),
         {:ok, _quote_mint} <- get_token_mint(vs_token_symbol) do
      case fetch_price_data(base_mint, token_symbol) do
        {:ok, price_float, confidence} ->
          :telemetry.execute(
            [:jupiter_bot, :perpetuals, :price_fetch],
            %{price: price_float, confidence: confidence || 0.0},
            %{token: "#{token_symbol}/#{vs_token_symbol}"}
          )
          {:reply, {:ok, %{"price" => price_float, "confidence" => confidence}}, state}
        error ->
          {:reply, error, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp fetch_price_data(base_mint, _token_symbol) do
    case get_price_data(base_mint) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            price = get_in(data, ["data", base_mint, "price"])
            confidence = get_in(data, ["data", base_mint, "confidence"])

            price_float = case price do
              nil -> nil
              p when is_binary(p) ->
                case Float.parse(p) do
                  {float_val, _} -> float_val
                  :error -> nil
                end
              p when is_float(p) -> p
              p when is_integer(p) -> p / 1
            end

            {:ok, price_float, confidence}

          error ->
            {:error, "Failed to decode price data: #{inspect(error)}"}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "API error: #{status}"}

      error ->
        {:error, "Failed to fetch price: #{inspect(error)}"}
    end
  end

  defp get_price_data(base_mint) do
    url = "#{@jupiter_price_api}?ids=#{base_mint}"
    Finch.build(:get, url)
    |> Finch.request(JupiterBot.HTTP, receive_timeout: 10_000)
  end

  defp get_token_mint(token_symbol) do
    case Map.fetch(@token_mints, token_symbol) do
      {:ok, mint} -> {:ok, mint}
      :error -> {:error, "Unknown token: #{token_symbol}"}
    end
  end
end
