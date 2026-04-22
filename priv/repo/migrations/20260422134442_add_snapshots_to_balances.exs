defmodule CashLens.Repo.Migrations.AddSnapshotsToBalances do
  use Ecto.Migration

  def change do
    alter table(:balances) do
      add :is_snapshot, :boolean, default: false, null: false
    end

    create index(:balances, [:account_id, :is_snapshot])
  end
end
