defmodule CashLens.Repo.Migrations.CreateCategoriesTable do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :type, :string, null: false
      add(:parent_id, references(:categories), null: true)

      timestamps()
    end

    create index(:categories, [:name])
    create unique_index(:categories, [:name, :type])
  end
end
