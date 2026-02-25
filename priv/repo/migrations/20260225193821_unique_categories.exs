defmodule CashLens.Repo.Migrations.UniqueCategories do
  use Ecto.Migration

  def up do
    # 1. Clean up duplicates (keep the first created one)
    execute """
    DELETE FROM categories a USING categories b
    WHERE a.id > b.id AND (a.slug = b.slug OR a.name = b.name)
    """

    # 2. Add unique indexes
    create unique_index(:categories, [:slug])
    create unique_index(:categories, [:name])
  end

  def down do
    drop index(:categories, [:slug])
    drop index(:categories, [:name])
  end
end
