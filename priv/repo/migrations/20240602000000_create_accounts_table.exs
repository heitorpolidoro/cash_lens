defmodule CashLens.Repo.Migrations.CreateAccountsTable do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string, null: false
      add :bank_name, :string, null: false
      add :type, :string, null: false
      add :parser, :string, null: false

      timestamps()
    end
  end
end
