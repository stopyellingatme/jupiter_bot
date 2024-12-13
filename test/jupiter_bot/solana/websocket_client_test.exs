defmodule JupiterBot.Solana.WebsocketClientTest do
  use ExUnit.Case
  alias JupiterBot.Solana.WebsocketClient

  setup do
    # Start PubSub for testing
    start_supervised!({Phoenix.PubSub, name: JupiterBot.PubSub})
    # Start the WebsocketClient with empty opts
    {:ok, pid} = WebsocketClient.start_link([])
    %{pid: pid}
  end

  test "handles price updates", %{pid: pid} do
    # Simulate receiving a price update
    price_update = %{
      "a" => "price",
      "b" => "SOL",
      "q" => "USD",
      "p" => "21795999999",
      "e" => -8,
      "t" => 1733888307798
    }

    # Subscribe to market updates
    Phoenix.PubSub.subscribe(JupiterBot.PubSub, "market_updates")

    # Call handle_frame directly on the WebsocketClient module
    {:ok, _state} = WebsocketClient.handle_frame(
      {:text, Jason.encode!(price_update)},
      %{prices: %{}}
    )

    # Assert we receive the broadcast
    assert_receive {:price_update, "SOL-USD", price, _timestamp}, 1000
    assert price > 0
  end
end
