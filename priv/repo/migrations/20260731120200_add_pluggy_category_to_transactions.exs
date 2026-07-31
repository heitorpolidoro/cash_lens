defmodule CashLens.Repo.Migrations.AddPluggyCategoryToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :pluggy_category, :string
    end
  end
end
