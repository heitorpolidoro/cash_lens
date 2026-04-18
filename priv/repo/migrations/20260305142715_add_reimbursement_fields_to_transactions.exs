defmodule CashLens.Repo.Migrations.AddReimbursementFieldsToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      # pending, requested, paid
      add :reimbursement_status, :string
      add :reimbursement_link_key, :uuid
    end

    create index(:transactions, [:reimbursement_link_key])
    create index(:transactions, [:reimbursement_status])
  end
end
