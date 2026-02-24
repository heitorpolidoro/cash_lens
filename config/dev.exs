import Config

# Configure your database
config :cash_lens, CashLens.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "db",
  database: "cash_lens_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :cash_lens, CashLensWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "W5xiLHJYLZLGWec4k54kErU+5FP+TeQAU4oxSqvxZfLTEdaLGm8uKJYFTP0OExpm",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:cash_lens, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:cash_lens, ~w(--watch)]}
  ],
  # Watchman is not installed in the Docker container, use the polling watcher
  reloadable_compilers: [:phoenix, :elixir],
  live_reload: [
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      # Gettext translations
      ~r"priv/gettext/.*\.po$",
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/cash_lens_web/router\.ex$",
      ~r"lib/cash_lens_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :cash_lens, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Force the file system watcher to use the default instead of watchman
config :file_system, :backend, :fs_inotify

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false
