defmodule CashLens.Repo.Migrations.CreateTransactionsTable do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :date, :date, null: false
      add :time, :time, null: true
      add :reason, :string, null: false
      add :category, :string, null: true
      add :amount, :decimal, precision: 10, scale: 2, null: false
      add :identifyer, :string, null: false

      timestamps()
    end
  end
end
