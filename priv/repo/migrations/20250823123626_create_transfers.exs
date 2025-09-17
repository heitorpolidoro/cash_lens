# TODO Review
defmodule CashLens.Repo.Migrations.CreateTransfers do
  use Ecto.Migration

  def change do
    create table(:transfers) do
      add :from_id, references(:transactions, on_delete: :restrict), null: true
      add :to_id, references(:transactions, on_delete: :restrict), null: true

      timestamps(type: :utc_datetime)
    end

    create index(:transfers, [:from_id])
    create index(:transfers, [:to_id])
    create unique_index(:transfers, [:from_id, :to_id])
  end
end
