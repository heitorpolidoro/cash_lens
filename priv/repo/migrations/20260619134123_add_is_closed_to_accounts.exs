defmodule CashLens.Repo.Migrations.AddIsClosedToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :is_closed, :boolean, default: false, null: false
    end
  end
end
