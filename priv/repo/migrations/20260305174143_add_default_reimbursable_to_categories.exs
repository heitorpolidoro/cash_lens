defmodule CashLens.Repo.Migrations.AddDefaultReimbursableToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      add :default_reimbursable, :boolean, default: false, null: false
    end
  end
end
