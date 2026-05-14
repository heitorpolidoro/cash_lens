defmodule CashLens.Repo.Migrations.MakeInstallmentGroupTotalAmountOptional do
  use Ecto.Migration

  def change do
    alter table(:installment_groups) do
      modify :total_amount, :decimal, null: true, from: :decimal
    end
  end
end
