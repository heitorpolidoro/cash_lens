defmodule CashLens.Repo.Migrations.OptimizeTransactionsAndSearch do
  use Ecto.Migration

  def change do
    # Enable pg_trgm for fuzzy text search
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # GIST index for fast text search on description
    create index(:transactions, ["description gist_trgm_ops"], using: :gist)

    # Composite index for transaction ordering (most frequent operation)
    create index(:transactions, [:date, :time, :inserted_at])

    # Index for transfer linking
    create index(:transactions, [:transfer_key])

    # Index for reimbursement linking
    create index(:transactions, [:reimbursement_link_key])
  end
end
