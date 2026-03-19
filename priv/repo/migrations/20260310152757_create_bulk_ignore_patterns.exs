defmodule CashLens.Repo.Migrations.CreateBulkIgnorePatterns do
  use Ecto.Migration

  def change do
    create table(:bulk_ignore_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pattern, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bulk_ignore_patterns, [:pattern])
  end
end
