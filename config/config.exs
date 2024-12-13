import Config

config :jupiter_bot,
  primary_rpc_node: System.get_env("SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"),
  wallet_pubkey: System.get_env("WALLET_PUBKEY"),
  ws_url: System.get_env("JUPITER_WS_URL")

config :jupiter_bot, JupiterBot.Solana.WebsocketClient,
  url: "wss://api.mainnet-beta.solana.com"

config :jupiter_bot, JupiterBot.Jupiter.PerpetualsClient,
  perp_api_url: "https://perp.jup.ag/v1",
  indexer_api_url: "https://perp-index.jup.ag/v1"

# Finch configuration
config :jupiter_bot, JupiterBot.HTTP,
  pools: %{
    :default => [
      size: 10,
      count: 1
    ]
  }

import_config "jupiter.exs"
