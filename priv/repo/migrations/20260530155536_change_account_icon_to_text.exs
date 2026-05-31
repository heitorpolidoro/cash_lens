defmodule CashLens.Repo.Migrations.ChangeAccountIconToText do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      modify :icon, :text
    end
  end
end
