defmodule CashLens.Repo.Migrations.AddTimeToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :time, :time
    end
  end
end
