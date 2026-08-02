defmodule CashLens.Repo.Migrations.AddSourceToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :source, :string
    end

    execute(
      "UPDATE transactions SET source = CASE WHEN pluggy_category IS NOT NULL THEN 'pluggy' ELSE 'file' END WHERE source IS NULL",
      ""
    )
  end
end
