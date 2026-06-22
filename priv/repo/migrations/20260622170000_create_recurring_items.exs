defmodule CashLens.Repo.Migrations.CreateRecurringItems do
  use Ecto.Migration

  def change do
    create table(:recurring_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :category_id, references(:categories, on_delete: :delete_all, type: :binary_id),
        null: false

      add :label, :string, null: false
      add :day_of_month, :integer, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :active, :boolean, null: false, default: true
      add :manually_edited, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recurring_items, [:category_id])
  end
end
