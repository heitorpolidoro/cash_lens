defmodule CashLens.Repo.Migrations.AddAbsorbedByToStatements do
  use Ecto.Migration

  def change do
    alter table(:credit_card_statements) do
      add :absorbed_by_statement_id,
          references(:credit_card_statements, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:credit_card_statements, [:absorbed_by_statement_id])
  end
end
