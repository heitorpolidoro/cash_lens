defmodule CashLens.Repo.Migrations.CreateTransactionsTable do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :date, :date, null: false
      add :time, :time, null: true
      add :reason, :string, null: false
      add :category, :string, null: true
      add :amount, :decimal, precision: 10, scale: 2, null: false
      add :identifier, :string, null: false
      add :account_id, references(:accounts), null: true

      timestamps()
    end

    create index(:transactions, [:account_id])
  end
end
