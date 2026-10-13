import Config

# Two database roles, as in dev: the suite runs as the unprivileged
# `cash_lens_app` role with forced row-level security. The owner repo exists only
# for the tests that need DDL (the migration test) and for ecto.migrate. The
# `test` alias provisions the app role (`mix cash_lens.db.provision`).
db_host = System.get_env("DATABASE_HOST") || "localhost"
db_port = String.to_integer(System.get_env("DATABASE_PORT") || "5432")
db_name = "cash_lens_test#{System.get_env("MIX_TEST_PARTITION")}"

config :cash_lens, CashLens.Repo,
  username: System.get_env("DATABASE_APP_USER") || "cash_lens_app",
  password: System.get_env("DATABASE_APP_PASSWORD") || "cash_lens_app",
  hostname: db_host,
  port: db_port,
  database: db_name,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :cash_lens, CashLens.MigrationRepo,
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD") || "postgres",
  hostname: db_host,
  port: db_port,
  database: db_name,
  priv: "priv/repo",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2

config :cash_lens, :start_migration_repo, true

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

# Cheap password hashing keeps the suite fast; production uses the default cost.
config :bcrypt_elixir, log_rounds: 1

config :cash_lens, :pdf_converter, CashLens.Parsers.PDFConverterMock
config :cash_lens, :start_console_reporter, false

# Configure Oban for testing
config :cash_lens, Oban, testing: :manual

# High limits so ordinary tests never trip the limiter; the rate-limit tests
# lower them explicitly.
config :cash_lens, CashLensWeb.Plugs.RateLimit,
  login: [limit: 100_000, window_seconds: 60],
  register: [limit: 100_000, window_seconds: 3600]

# Sentry events are collected in-process (Sentry.Test) instead of being sent.
config :sentry, test_mode: true

config :cash_lens, :auto_create_owner, true
