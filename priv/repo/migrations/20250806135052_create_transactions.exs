# TODO Review
defmodule CashLens.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :datetime, :utc_datetime, null: false
      add :amount, :decimal, precision: 10, scale: 2, null: false
      add :reason, :string
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :category_id, references(:categories, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:account_id])
    create index(:transactions, [:category_id])
    create index(:transactions, [:datetime])
    create index(:transactions, [:amount])
    create index(:transactions, [:reason])
  end
end
