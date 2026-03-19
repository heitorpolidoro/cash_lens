defmodule CashLens.Repo.Migrations.AddParserTypeToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :parser_type, :string
    end
  end
end
