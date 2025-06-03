defmodule CashLens.Repo.Migrations.CreateTransactionsTable do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add(:date_time, :utc_datetime, null: false)
      add(:reason, :string, null: false)
      add(:amount, :decimal, precision: 10, scale: 2, null: false)
      add(:identifier, :string, null: false)
      add(:category_id, references(:categories), null: true)
      add(:account_id, references(:accounts), null: true)
      add(:user_id, references(:users), null: false)

      timestamps()
    end

    create(index(:transactions, [:account_id]))
  end
end
