defmodule CashLens.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string
      add :bank_name, :string
      add :type, :string

      timestamps(type: :utc_datetime)
    end

    create index(:accounts, [:name, :bank_name])
  end
end
