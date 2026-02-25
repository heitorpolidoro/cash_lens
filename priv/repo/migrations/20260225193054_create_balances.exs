defmodule CashLens.Repo.Migrations.CreateBalances do
  use Ecto.Migration

  def change do
    create table(:balances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :year, :integer
      add :month, :integer
      add :initial_balance, :decimal
      add :income, :decimal
      add :expenses, :decimal
      add :balance, :decimal
      add :final_balance, :decimal
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:balances, [:account_id])
  end
end
