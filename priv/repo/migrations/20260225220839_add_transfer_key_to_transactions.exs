defmodule CashLens.Repo.Migrations.AddTransferKeyToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :transfer_key, :uuid
    end

    create index(:transactions, [:transfer_key])
  end
end
