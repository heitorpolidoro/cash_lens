defmodule CashLens.Repo.Migrations.CreatePluggyAccountLinks do
  use Ecto.Migration

  def change do
    create table(:pluggy_account_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pluggy_item_id, references(:pluggy_items, on_delete: :delete_all, type: :binary_id),
        null: false

      add :pluggy_account_id, :string, null: false
      add :pluggy_account_name, :string
      add :pluggy_account_type, :string

      add :account_id, references(:accounts, on_delete: :nilify_all, type: :binary_id)

      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pluggy_account_links, [:pluggy_item_id, :pluggy_account_id])
    create index(:pluggy_account_links, [:account_id])
  end
end
