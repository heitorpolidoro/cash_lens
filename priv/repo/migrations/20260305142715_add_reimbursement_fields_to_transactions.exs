defmodule CashLens.Repo.Migrations.AddReimbursementFieldsToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :reimbursement_status, :string # pending, requested, paid
      add :reimbursement_link_key, :uuid
    end

    create index(:transactions, [:reimbursement_link_key])
    create index(:transactions, [:reimbursement_status])
  end
end
