defmodule CashLens.Repo.Migrations.OptimizeTransactionsAndSearch do
  use Ecto.Migration

  def up do
    # Enable pg_trgm for fuzzy text search
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # GIST index for fast text search on description
    # Explicitly using gin_trgm_ops for standard trigram search, but gist is fine if preferred.
    # Sticking to GIST as originally intended but with proper direction.
    create_if_not_exists index(:transactions, ["description gist_trgm_ops"],
                           using: :gist,
                           name: :transactions_description_trgm_index
                         )

    # Composite index for transaction ordering (most frequent operation)
    # Added explicit directions to match UI usage
    create_if_not_exists index(:transactions, [desc: :date, desc: :time, desc: :inserted_at],
                           name: :transactions_ordering_index
                         )

    # Index for transfer linking
    create_if_not_exists index(:transactions, [:transfer_key],
                           name: :transactions_transfer_key_index
                         )

    # Index for reimbursement linking
    create_if_not_exists index(:transactions, [:reimbursement_link_key],
                           name: :transactions_reimbursement_link_key_index
                         )
  end

  def down do
    drop_if_exists index(:transactions, name: :transactions_reimbursement_link_key_index)
    drop_if_exists index(:transactions, name: :transactions_transfer_key_index)
    drop_if_exists index(:transactions, name: :transactions_ordering_index)
    drop_if_exists index(:transactions, name: :transactions_description_trgm_index)
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
