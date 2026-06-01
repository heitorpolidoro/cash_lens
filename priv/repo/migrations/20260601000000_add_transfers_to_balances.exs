defmodule CashLens.Repo.Migrations.AddTransfersToBalances do
  use Ecto.Migration

  def change do
    alter table(:balances) do
      add :transfers_in, :decimal, default: 0, null: false
      add :transfers_out, :decimal, default: 0, null: false
    end
  end
end
