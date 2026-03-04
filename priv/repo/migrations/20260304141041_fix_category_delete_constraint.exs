defmodule CashLens.Repo.Migrations.FixCategoryDeleteConstraint do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_category_id_fkey"
    execute "ALTER TABLE transactions ADD CONSTRAINT transactions_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL"
  end

  def down do
    execute "ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_category_id_fkey"
    execute "ALTER TABLE transactions ADD CONSTRAINT transactions_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories(id)"
  end
end
