defmodule CashLens.Repo.Migrations.AddAcceptsImportToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :accepts_import, :boolean, default: true, null: false
    end
  end
end
