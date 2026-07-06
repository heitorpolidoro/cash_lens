defmodule CashLens.Repo.Migrations.CreateCreditCardStatements do
  use Ecto.Migration

  def change do
    create table(:credit_card_statements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, on_delete: :delete_all, type: :binary_id),
        null: false

      add :competencia, :date
      add :due_date, :date
      add :total_a_pagar, :decimal
      add :source_file, :string

      add :payment_transaction_id,
          references(:transactions, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:credit_card_statements, [:account_id])
    create index(:credit_card_statements, [:payment_transaction_id])

    alter table(:transactions) do
      add :import_batch_id, :binary_id
    end

    create index(:transactions, [:import_batch_id])
  end
end
