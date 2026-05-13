defmodule CashLens.Repo.Migrations.CreateInstallmentGroups do
  use Ecto.Migration

  def change do
    create table(:installment_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :description_pattern, :string, null: false
      add :total_amount, :decimal, precision: 15, scale: 2, null: false
      add :installments, :integer, null: false
      add :start_date, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:installment_groups, [:description_pattern])

    alter table(:transactions) do
      add :installment_group_id,
          references(:installment_groups, on_delete: :nothing, type: :binary_id)

      add :installment_number, :integer
    end

    create index(:transactions, [:installment_group_id])
  end
end
