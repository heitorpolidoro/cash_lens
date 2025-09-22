# TODO Review
defmodule CashLens.Repo.Migrations.CreateReasons do
  use Ecto.Migration

  def change do
    create table(:reasons) do
      add :reason, :string
      add :category_id, references(:categories, on_delete: :restrict), null: true
      add :refundable, :bool, default: false, null: false
      add :ignore, :bool, default: false, null: false
      add :parent_id, references(:reasons, on_delete: :restrict), null: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reasons, [:reason])
  end
end
