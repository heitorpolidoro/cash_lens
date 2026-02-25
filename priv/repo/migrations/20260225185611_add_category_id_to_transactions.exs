defmodule CashLens.Repo.Migrations.AddCategoryIdToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      remove :category
      add :category_id, references(:categories, on_delete: :nothing, type: :binary_id)
    end

    create index(:transactions, [:category_id])
  end
end
