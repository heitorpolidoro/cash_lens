defmodule CashLens.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string
      add :fixed, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:name])
  end
end
