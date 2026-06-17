defmodule CashLens.Repo.Migrations.CreateRejectedReimbursementPairs do
  use Ecto.Migration

  def change do
    create table(:rejected_reimbursement_pairs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transaction_a_id, references(:transactions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :transaction_b_id, references(:transactions, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rejected_reimbursement_pairs, [:transaction_a_id])
    create index(:rejected_reimbursement_pairs, [:transaction_b_id])
    create unique_index(:rejected_reimbursement_pairs, [:transaction_a_id, :transaction_b_id])
  end
end
