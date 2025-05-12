defmodule CashLens.Repo.Migrations.CreateReasonsToIgnoreTable do
  use Ecto.Migration

  def change do
    create table(:reasons_to_ignore) do
      add(:reason, :string, null: false)
      add(:parser, :string, null: false)

      timestamps()
    end
  end
end
