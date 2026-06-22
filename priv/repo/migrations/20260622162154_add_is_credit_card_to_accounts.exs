defmodule CashLens.Repo.Migrations.AddIsCreditCardToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :is_credit_card, :boolean, default: false, null: false
    end
  end
end
