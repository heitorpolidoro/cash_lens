defmodule CashLens.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string
      add :bank_name, :string
      add :type, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, ["lower(name)", "lower(bank_name)"],
             name: :accounts_name_bank_name_index
           )
  end
end
