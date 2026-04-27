defmodule CashLens.Transactions.AutoCategorizerTest do
  use CashLens.DataCase, async: false
  alias CashLens.Transactions.AutoCategorizer
  import CashLens.CategoriesFixtures

  describe "categorize/1" do
    test "matches category by keywords" do
      category = category_fixture(%{name: "Food", keywords: "IFOOD,RESTAURANT,MARKET"})

      params = %{description: "IFOOD * LUNCH"}
      result = AutoCategorizer.categorize(params)

      assert result.category_id == category.id
    end

    test "marks as pending reimbursement if category is default_reimbursable" do
      category =
        category_fixture(%{
          name: "Health",
          keywords: "PHARMACY",
          default_reimbursable: true
        })

      params = %{description: "PHARMACY EXPENDITURE"}
      result = AutoCategorizer.categorize(params)

      assert result.category_id == category.id
      assert result.reimbursement_status == "pending"
    end

    test "applies special rules for transfers" do
      # Ensure transfer category exists
      category = category_fixture(%{name: "Transfer", slug: "transfer", keywords: ""})

      params = %{description: "BB MM OURO TRANSACTION"}
      result = AutoCategorizer.categorize(params)

      assert result.category_id == category.id
    end

    test "returns original params if no match" do
      params = %{description: "UNKNOWN STORE"}
      result = AutoCategorizer.categorize(params)

      assert result == params
      assert is_nil(Map.get(result, :category_id))
    end

    test "handles multiple keywords and formats" do
      category = category_fixture(%{name: "Fuel", keywords: "POSTO,GAS,FUEL"})

      # Test lowercase description match
      params = %{description: "posto de gasolina"}
      result = AutoCategorizer.categorize(params)
      assert result.category_id == category.id
    end

    test "assign_category_by_slug returns original params if category not found" do
      # We don't create any category here
      _params = %{description: "RANDOM"}
      # Triggering check_special_rules with a string that matches but has no category in DB
      params_with_transfer_desc = %{description: "BB MM OURO"}
      result = AutoCategorizer.categorize(params_with_transfer_desc)
      assert result == params_with_transfer_desc
    end
  end
end
