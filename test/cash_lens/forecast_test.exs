defmodule CashLens.ForecastTest do
  use CashLens.DataCase, async: false

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures

  describe "create_recurring_item/1" do
    test "creates with valid attrs" do
      category = category_fixture(%{type: "fixed"})

      assert {:ok, %RecurringItem{} = item} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: category.name,
                 day_of_month: 10,
                 amount: "-100.00"
               })

      assert item.day_of_month == 10
      assert Decimal.equal?(item.amount, "-100.00")
      assert item.active == true
      assert item.manually_edited == false
    end

    test "rejects day_of_month outside 1..31" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 32,
                 amount: "-10.00"
               })

      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end

    test "rejects amount of zero" do
      category = category_fixture(%{type: "fixed"})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "x",
                 day_of_month: 10,
                 amount: "0"
               })

      assert "não pode ser zero" in errors_on(changeset).amount
    end

    test "rejects a second item for the same category" do
      category = category_fixture(%{type: "fixed"})
      recurring_item_fixture(%{category_id: category.id})

      assert {:error, changeset} =
               Forecast.create_recurring_item(%{
                 category_id: category.id,
                 label: "dup",
                 day_of_month: 5,
                 amount: "-1.00"
               })

      assert "has already been taken" in errors_on(changeset).category_id
    end
  end
end
