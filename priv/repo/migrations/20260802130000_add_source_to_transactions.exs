defmodule CashLens.Repo.Migrations.AddSourceToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :source, :string
    end

    # Down is intentionally a no-op: Ecto auto-reverses `alter table ... add
    # :source` into a column drop, which already undoes this backfill along
    # with the column itself, so there is nothing left to reverse here.
    execute(
      "UPDATE transactions SET source = CASE WHEN pluggy_category IS NOT NULL THEN 'pluggy' ELSE 'file' END WHERE source IS NULL",
      ""
    )
  end
end
