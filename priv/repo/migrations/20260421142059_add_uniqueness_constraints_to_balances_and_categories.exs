defmodule CashLens.Repo.Migrations.AddUniquenessConstraintsToBalancesAndCategories do
  use Ecto.Migration

  def change do
    # 1. Uniqueness for balances: Only one balance record per account/month/year
    create unique_index(:balances, [:account_id, :year, :month],
             name: :balances_account_year_month_index
           )

    # 2. Uniqueness for categories: Parent categories can't have children with the same name
    # We use a conditional index for parent_id being nil (top-level categories)
    create unique_index(:categories, [:name],
             where: "parent_id IS NULL",
             name: :categories_top_level_name_index
           )

    create unique_index(:categories, [:parent_id, :name],
             where: "parent_id IS NOT NULL",
             name: :categories_sub_level_name_index
           )
  end
end
