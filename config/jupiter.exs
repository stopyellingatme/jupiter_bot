import Config

config :jupiter_bot, JupiterBot.Jupiter,
  perp_api_url: "https://perp.jup.ag/v1",
  indexer_api_url: "https://perp-index.jup.ag/v1",
  rpc_url: System.get_env("SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"),
  ws_url: System.get_env("JUPITER_WS_URL"),
  helius_api_key: System.get_env("HELIUS_API_KEY"),
  priority_fee_level: "veryHigh",
  max_slippage_bps: 300,
  max_priority_fee_lamports: 10_000_000
