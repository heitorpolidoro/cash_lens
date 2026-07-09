defmodule CashLens.Repo.Migrations.AddBillingCycleToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :closing_day, :integer
      add :due_day, :integer
    end
  end
end
