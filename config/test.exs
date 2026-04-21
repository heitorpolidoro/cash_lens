import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cash_lens, CashLens.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cash_lens_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cash_lens, CashLensWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "esta_chave_secreta_e_longa_o_suficiente_para_passar_na_validacao_do_plug_e_garantir_que_os_testes_funcionem_corretamente",
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

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :cash_lens, sql_sandbox: true
