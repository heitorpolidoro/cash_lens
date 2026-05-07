defmodule CashLens.Repo.Migrations.InitialSetup do
  use Ecto.Migration

  def up do
    # 1. Extensions
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    # 2. Oban (Latest version)
    Oban.Migration.up()

    # 3. Create Tables
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :bank, :string
      add :balance, :decimal
      add :color, :string
      add :icon, :string
      add :accepts_import, :boolean, default: true, null: false
      add :parser_type, :string

      timestamps(type: :utc_datetime)
    end

    create table(:categories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :slug, :string
      add :parent_id, references(:categories, on_delete: :nothing, type: :binary_id)
      add :keywords, :text
      add :default_reimbursable, :boolean, default: false, null: false
      add :type, :string, default: "variable", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:categories, [:parent_id])
    create index(:categories, [:type])
    create unique_index(:categories, [:slug])

    create unique_index(:categories, [:name],
             where: "parent_id IS NULL",
             name: :categories_top_level_name_index
           )

    create unique_index(:categories, [:parent_id, :name],
             where: "parent_id IS NOT NULL",
             name: :categories_sub_level_name_index
           )

    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date
      add :time, :time
      add :description, :string
      add :amount, :decimal
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)
      add :category_id, references(:categories, on_delete: :nilify_all, type: :binary_id)
      add :transfer_key, :uuid
      add :fingerprint, :string
      add :reimbursement_status, :string
      add :reimbursement_link_key, :uuid

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:account_id])
    create index(:transactions, [:category_id])
    create index(:transactions, [:transfer_key])
    create index(:transactions, [:reimbursement_link_key])
    create index(:transactions, [:reimbursement_status])
    create unique_index(:transactions, [:fingerprint])

    # Search and Ordering Indexes
    execute "CREATE INDEX transactions_description_trgm_index ON transactions USING gist (description gist_trgm_ops)"

    create index(:transactions, [desc: :date, desc: :time, desc: :inserted_at],
             name: :transactions_ordering_index
           )

    create table(:balances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :year, :integer
      add :month, :integer
      add :initial_balance, :decimal
      add :income, :decimal
      add :expenses, :decimal
      add :balance, :decimal
      add :final_balance, :decimal
      add :is_snapshot, :boolean, default: false, null: false
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:balances, [:account_id])
    create index(:balances, [:account_id, :is_snapshot])

    create unique_index(:balances, [:account_id, :year, :month],
             name: :balances_account_year_month_index
           )

    create table(:bulk_ignore_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pattern, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bulk_ignore_patterns, [:pattern])
  end

  def down do
    drop table(:bulk_ignore_patterns)
    drop table(:balances)
    drop table(:transactions)
    drop table(:categories)
    drop table(:accounts)
    Oban.Migration.down()
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
