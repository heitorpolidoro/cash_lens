defmodule CashLens.Repo.Migrations.AddTypeToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      # fixed or variable
      add :type, :string, default: "variable", null: false
    end

    create index(:categories, [:type])
  end
end
