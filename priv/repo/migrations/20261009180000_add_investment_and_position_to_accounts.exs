defmodule CashLens.Repo.Migrations.AddInvestmentAndPositionToAccounts do
  use Ecto.Migration

  # Two things the accounts list was missing.
  #
  # `is_investment` marks money that is not spending money. It is a label: the
  # balances it carries go on counting exactly as they did, and nothing in the
  # forecast changes.
  #
  # `position` is the order the lists read in. There was none -- `list_accounts/1`
  # had no `order_by` at all, so the dashboard showed whatever Postgres handed
  # back, and an update could silently reshuffle it. Null means "not placed
  # yet" and sorts last, behind everything the user has arranged.

  def change do
    alter table(:accounts) do
      add :is_investment, :boolean, default: false, null: false
      add :position, :integer
    end

    create index(:accounts, [:position])
  end
end
