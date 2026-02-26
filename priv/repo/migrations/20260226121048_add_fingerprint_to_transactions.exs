defmodule CashLens.Repo.Migrations.AddFingerprintToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :fingerprint, :string
    end

    create unique_index(:transactions, [:fingerprint])
  end
end
