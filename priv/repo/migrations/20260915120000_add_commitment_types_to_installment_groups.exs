defmodule CashLens.Repo.Migrations.AddCommitmentTypesToInstallmentGroups do
  use Ecto.Migration

  def change do
    alter table(:installment_groups) do
      # Existing rows are all credit-card instalment purchases, so the default
      # keeps them behaving exactly as before.
      add :commitment_type, :string, null: false, default: "credit_card"
      add :institution, :string
      # Financing-only fields.
      add :interest_rate, :decimal, precision: 8, scale: 4
      # Consórcio-only fields.
      add :credit_letter_amount, :decimal, precision: 15, scale: 2
      add :is_contemplated, :boolean, null: false, default: false
      add :contemplated_at, :date
    end

    create index(:installment_groups, [:commitment_type])
  end
end
