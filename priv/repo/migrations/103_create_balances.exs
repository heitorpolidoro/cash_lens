# TODO Review
defmodule CashLens.Repo.Migrations.CreateBalances do
  use Ecto.Migration

  def change do
    create table(:balances) do
      add :month, :date, null: false
      add :starting_value, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :total_in, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :total_out, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :balance, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :interest, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :final_value, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :account_id, references(:accounts, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:balances, [:account_id])
    create unique_index(:balances, [:account_id, :month], name: :unique_account_month)
    create index(:balances, [:month])
  end
end
