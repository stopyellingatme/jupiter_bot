defmodule JupiterBot.Solana.RPCClient do
  use GenServer
  require Logger

  @retry_attempts 3
  @backup_nodes ["https://backup1.solana.com", "https://backup2.solana.com"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_account_info(pubkey) do
    GenServer.call(__MODULE__, {:get_account_info, pubkey})
  end

  def send_transaction(transaction) do
    GenServer.call(__MODULE__, {:send_transaction, transaction})
  end

  @impl true
  def init(_opts) do
    {:ok, %{
      current_node: Application.get_env(:jupiter_bot, :primary_rpc_node),
      retry_count: 0
    }}
  end

  @impl true
  def handle_call({:send_transaction, transaction}, from, state) do
    case do_send_transaction(transaction, state) do
      {:ok, _signature} = result ->
        {:reply, result, %{state | retry_count: 0}}
      {:error, _reason} when state.retry_count < @retry_attempts ->
        new_state = handle_retry(state)
        handle_call({:send_transaction, transaction}, from, new_state)
      error ->
        {:reply, error, %{state | retry_count: 0}}
    end
  end

  defp do_send_transaction(transaction, state) do
    # Initialize the Solana RPC client
    client = Solana.RPC.client(
      network: state.current_node,
      adapter: {Tesla.Adapter.Gun, certificates_verification: true}
    )

    # Make sure you have the correct Solana package version that includes this function
    # or implement your own send_transaction function
    case Solana.RPC.send_encoded_transaction(client, transaction) do
      {:ok, signature} -> {:ok, signature}
      error -> error
    end
  end

  defp handle_retry(state) do
    next_node = Enum.at(@backup_nodes, state.retry_count)
    Logger.warning("Switching to backup node: #{next_node}")
    %{state |
      current_node: next_node,
      retry_count: state.retry_count + 1
    }
  end

  @impl true
  def handle_call({:get_account_info, nil}, _from, state) do
    # Return default response when no pubkey is provided
    {:reply, {:ok, %{total_usd: 1000.00, available_usd: 800.00}}, state}
  end

  @impl true
  def handle_call({:get_account_info, pubkey}, _from, state) do
    # Mock implementation for testing
    {:reply, {:ok, %{total_usd: 1000.00, available_usd: 800.00}}, state}
  end
end
