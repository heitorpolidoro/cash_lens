defmodule CashLens.Repo.Migrations.AddParentIdToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      add :parent_id, references(:categories, on_delete: :nothing, type: :binary_id)
      add :keywords, :text
    end

    create index(:categories, [:parent_id])
  end
end
