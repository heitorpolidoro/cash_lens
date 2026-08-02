defmodule CashLens.Repo.Migrations.AddBalanceToPluggyAccountLinks do
  use Ecto.Migration

  def change do
    alter table(:pluggy_account_links) do
      add :pluggy_balance, :decimal
    end
  end
end
