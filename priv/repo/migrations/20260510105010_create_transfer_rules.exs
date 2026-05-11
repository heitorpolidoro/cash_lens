defmodule CashLens.Repo.Migrations.CreateTransferRules do
  use Ecto.Migration

  def change do
    create table(:transfer_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string
      add :description_patterns, {:array, :string}, null: false, default: []

      add :source_account_id, references(:accounts, on_delete: :delete_all, type: :binary_id),
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
  end
end
