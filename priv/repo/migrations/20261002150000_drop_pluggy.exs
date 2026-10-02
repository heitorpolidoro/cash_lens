defmodule CashLens.Repo.Migrations.DropPluggy do
  use Ecto.Migration

  # Removes the Open Finance (Pluggy) integration from the schema.
  #
  # `transactions.source` is deliberately KEPT: despite having arrived with the
  # Pluggy work, it distinguishes `"file"` from `"manual"` rows and is read all
  # over the app. Only the `"pluggy"` value disappears, and no row carried it.
  #
  # `docs/pluggy-reference.md` records what the integration did and what would
  # be needed to bring it back; `docs/pluggy/pluggy-data-snapshot.sql` holds the
  # rows these tables had when they were dropped.

  def up do
    alter table(:transactions) do
      remove :pluggy_category
    end

    drop table(:pluggy_account_links)
    drop table(:pluggy_items)
  end

  def down do
    create table(:pluggy_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pluggy_items, [:item_id])

    create table(:pluggy_account_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pluggy_item_id, references(:pluggy_items, type: :binary_id, on_delete: :delete_all)
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all)
      add :pluggy_account_id, :string, null: false
      add :pluggy_account_name, :string
      add :pluggy_account_type, :string
      add :pluggy_balance, :decimal

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pluggy_account_links, [:pluggy_account_id])

    alter table(:transactions) do
      add :pluggy_category, :string
    end
  end
end
