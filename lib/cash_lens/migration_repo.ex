defmodule CashLens.MigrationRepo do
  @moduledoc """
  The owner/migrator repo. It connects as the role that owns the tables and is
  used only for DDL: `mix ecto.migrate`, release migrations, role provisioning
  and the schema tests. It is never started with the application in prod or dev
  (see `:start_migration_repo`), and the runtime code must not use it.

  Both repos share `priv/repo`, so migrations live in one place. Since the
  owner is subject to `FORCE ROW LEVEL SECURITY` like everyone else, data
  maintenance run through this repo needs `CashLens.Repo.with_user/2` or a
  migration that handles the policies explicitly.
  """
  use Ecto.Repo,
    otp_app: :cash_lens,
    adapter: Ecto.Adapters.Postgres
end
