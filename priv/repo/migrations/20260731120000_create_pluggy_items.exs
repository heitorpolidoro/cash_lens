defmodule CashLens.Repo.Migrations.CreatePluggyItems do
  use Ecto.Migration

  def change do
    create table(:pluggy_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime)
    end
  end
end
