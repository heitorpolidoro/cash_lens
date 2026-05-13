defmodule CashLens.Repo.Migrations.AddNotesToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :notes, :text
    end
  end
end
