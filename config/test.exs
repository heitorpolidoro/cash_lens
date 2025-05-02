import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cash_lens, CashLensWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Nh1ruaJoAw6sIJfNVj8zgRhuKxsTS+Yfrtjnfo+1pzKPEggNky9feJo/iZfxR3CP",
  server: false

# In test we don't send emails
config :cash_lens, CashLens.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Configure your database
config :cash_lens, CashLens.Repo,
  username: System.get_env("POSTGRES_USER", "your-postgres-user"),
  password: System.get_env("POSTGRES_PASSWORD", "your-postgres-password"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "#{System.get_env("POSTGRES_DB", "cash_lens")}_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
