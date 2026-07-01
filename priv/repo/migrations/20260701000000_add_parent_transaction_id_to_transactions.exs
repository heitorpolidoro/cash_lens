defmodule CashLens.Repo.Migrations.AddParentTransactionIdToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :parent_transaction_id,
          references(:transactions, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:transactions, [:parent_transaction_id])
  end
end
