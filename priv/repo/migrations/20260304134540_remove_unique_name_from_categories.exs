defmodule CashLens.Repo.Migrations.RemoveUniqueNameFromCategories do
  use Ecto.Migration

  def change do
    drop index(:categories, [:name])
  end
end
