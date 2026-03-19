defmodule CashLens.Repo.Migrations.AddTypeToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      add :type, :string, default: "variable", null: false # fixed or variable
    end

    create index(:categories, [:type])
  end
end
