defmodule CashLens.Repo.Migrations.CreateImportRuns do
  use Ecto.Migration

  def change do
    create table(:import_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ran_at, :utc_datetime, null: false
      add :account_id, references(:accounts, on_delete: :nilify_all, type: :binary_id)

      add :imported_file_id,
          references(:imported_files, on_delete: :nilify_all, type: :binary_id)

      add :file_path, :string, null: false
      add :status, :string, null: false
      add :imported_count, :integer, default: 0
      add :skipped_count, :integer, default: 0
      add :failed_count, :integer, default: 0
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:import_runs, [:ran_at])
    create index(:import_runs, [:account_id])
    create index(:import_runs, [:imported_file_id])
  end
end
