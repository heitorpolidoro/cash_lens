# TODO Review
defmodule CashLens.Repo.Migrations.CreateAutomaticTransferTable do
  use Ecto.Migration

  def change do
    create table(:automatic_transfers) do
      add :from_id, references(:accounts, on_delete: :restrict), null: true
      add :to_id, references(:accounts, on_delete: :restrict), null: true

      timestamps(type: :utc_datetime)
    end

    create index(:automatic_transfers, [:from_id])
    create index(:automatic_transfers, [:to_id])
    create unique_index(:automatic_transfers, [:from_id, :to_id])
  end
end
