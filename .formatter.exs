[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/repo/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs,heex}"]
]
