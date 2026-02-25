defmodule CashLens.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date
      add :description, :string
      add :amount, :decimal
      add :category, :string
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:account_id])
  end
end
