defmodule CashLens.Repo.Migrations.ConsolidatedSchema do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    Oban.Migration.up()

    # ── accounts ──────────────────────────────────────────────────────────
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :bank, :string
      add :balance, :decimal
      add :color, :string
      add :icon, :text
      add :accepts_import, :boolean, default: true, null: false
      add :parser_type, :string
      add :is_closed, :boolean, default: false, null: false
      add :is_credit_card, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    # ── categories ────────────────────────────────────────────────────────
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

    # ── installment_groups ────────────────────────────────────────────────
    create table(:installment_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :description_pattern, :string, null: false
      add :total_amount, :decimal, precision: 15, scale: 2
      add :installments, :integer, null: false
      add :start_date, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:installment_groups, [:description_pattern])

    # ── transactions ──────────────────────────────────────────────────────
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date
      add :time, :time
      add :description, :string
      add :amount, :decimal
      add :notes, :text
      add :dedup_key, :string
      add :fingerprint, :string
      add :transfer_key, :uuid
      add :reimbursement_status, :string
      add :reimbursement_link_key, :uuid
      add :installment_number, :integer

      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)
      add :category_id, references(:categories, on_delete: :nilify_all, type: :binary_id)

      add :installment_group_id,
          references(:installment_groups, on_delete: :nothing, type: :binary_id)

      add :parent_transaction_id,
          references(:transactions, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:account_id])
    create index(:transactions, [:category_id])
    create index(:transactions, [:transfer_key])
    create index(:transactions, [:reimbursement_link_key])
    create index(:transactions, [:reimbursement_status])
    create index(:transactions, [:dedup_key])
    create index(:transactions, [:installment_group_id])
    create index(:transactions, [:parent_transaction_id])
    create unique_index(:transactions, [:fingerprint])

    execute "CREATE INDEX transactions_description_trgm_index ON transactions USING gist (description gist_trgm_ops)"

    create index(:transactions, [desc: :date, desc: :time, desc: :inserted_at],
             name: :transactions_ordering_index
           )

    # ── balances ──────────────────────────────────────────────────────────
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
      add :transfers_in, :decimal, default: 0, null: false
      add :transfers_out, :decimal, default: 0, null: false
      add :account_id, references(:accounts, on_delete: :nothing, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:balances, [:account_id])
    create index(:balances, [:account_id, :is_snapshot])

    create unique_index(:balances, [:account_id, :year, :month],
             name: :balances_account_year_month_index
           )

    # ── bulk_ignore_patterns ──────────────────────────────────────────────
    create table(:bulk_ignore_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pattern, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bulk_ignore_patterns, [:pattern])

    # ── transfer_rules ────────────────────────────────────────────────────
    create table(:transfer_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string
      add :description_patterns, {:array, :string}, null: false, default: []
      add :create_mirror, :boolean, default: true, null: false

      add :source_account_id,
          references(:accounts, on_delete: :delete_all, type: :binary_id),
          null: false

      add :destination_account_id,
          references(:accounts, on_delete: :delete_all, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:transfer_rules, [:source_account_id])
    create index(:transfer_rules, [:destination_account_id])

    create constraint(:transfer_rules, :source_destination_differ,
             check: "source_account_id <> destination_account_id"
           )

    # ── rejected_reimbursement_pairs ──────────────────────────────────────
    create table(:rejected_reimbursement_pairs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transaction_a_id,
          references(:transactions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :transaction_b_id,
          references(:transactions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rejected_reimbursement_pairs, [:transaction_a_id])
    create index(:rejected_reimbursement_pairs, [:transaction_b_id])
    create unique_index(:rejected_reimbursement_pairs, [:transaction_a_id, :transaction_b_id])

    # ── recurring_items ───────────────────────────────────────────────────
    create table(:recurring_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :category_id,
          references(:categories, on_delete: :delete_all, type: :binary_id),
          null: false

      add :label, :string, null: false
      add :day_of_month, :integer, null: false
      add :amount, :decimal, precision: 15, scale: 2, null: false
      add :active, :boolean, null: false, default: true
      add :manually_edited, :boolean, null: false, default: false
      add :is_salary, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recurring_items, [:category_id])
  end

  def down do
    drop table(:recurring_items)
    drop table(:rejected_reimbursement_pairs)
    drop table(:transfer_rules)
    drop table(:bulk_ignore_patterns)
    drop table(:balances)
    drop table(:transactions)
    drop table(:installment_groups)
    drop table(:categories)
    drop table(:accounts)
    Oban.Migration.down()
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
