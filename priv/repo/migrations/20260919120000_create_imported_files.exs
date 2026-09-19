defmodule CashLens.Repo.Migrations.CreateImportedFiles do
  use Ecto.Migration

  def change do
    create table(:imported_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false
      add :content_hash, :string
      add :mtime, :utc_datetime
      add :last_imported_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:imported_files, [:path])
  end
end
