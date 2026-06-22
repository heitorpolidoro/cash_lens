defmodule CashLens.ForecastTest do
  use CashLens.DataCase, async: false

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures

  describe "suggest_for_category/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "returns :insufficient_history with fewer than 2 occurrences" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end

    test "suggests the median day and the most recent amount" do
      category = category_fixture(%{type: "fixed"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-12],
        amount: "-52.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-55.00"
      })

      assert {:ok, %{"day_of_month" => 12, "amount" => amount}} =
               Forecast.suggest_for_category(category)

      assert Decimal.equal?(amount, "-55.00")
    end

    test "ignores transactions on credit card accounts" do
      category = category_fixture(%{type: "fixed"})
      cc_account = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-04-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: cc_account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      assert Forecast.suggest_for_category(category) == :insufficient_history
    end
  end

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

  describe "list_recurring_items/0 and get_recurring_item!/1" do
    test "lists items ordered by day_of_month" do
      recurring_item_fixture(%{day_of_month: 20})
      recurring_item_fixture(%{day_of_month: 5})

      assert [first, second] = Forecast.list_recurring_items()
      assert first.day_of_month == 5
      assert second.day_of_month == 20
    end

    test "get_recurring_item!/1 fetches by id" do
      item = recurring_item_fixture()
      assert Forecast.get_recurring_item!(item.id).id == item.id
    end
  end

  describe "sync_all/0" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "creates an item for a fixed category with enough history" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-52.00"
      })

      assert Forecast.sync_all() == %{created: 1, updated: 0}
      assert [item] = Forecast.list_recurring_items()
      assert item.label == "Água"
      assert item.day_of_month == 10
    end

    test "does not create an item for a category with insufficient history" do
      category_fixture(%{type: "fixed", name: "Sem histórico"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
      assert Forecast.list_recurring_items() == []
    end

    test "ignores variable categories" do
      category_fixture(%{type: "variable", name: "Mercado"})

      assert Forecast.sync_all() == %{created: 0, updated: 0}
    end

    test "updates an existing non-manually-edited item, leaves manually-edited ones alone" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      auto_item =
        recurring_item_fixture(%{category_id: category.id, day_of_month: 1, amount: "-1.00"})

      assert Forecast.sync_all() == %{created: 0, updated: 1}

      reloaded = Forecast.get_recurring_item!(auto_item.id)
      assert reloaded.day_of_month == 10
      assert Decimal.equal?(reloaded.amount, "-60.00")
    end

    test "leaves a manually_edited item untouched" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-15],
        amount: "-60.00"
      })

      edited_item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert Forecast.sync_all() == %{created: 0, updated: 0}

      reloaded = Forecast.get_recurring_item!(edited_item.id)
      assert reloaded.day_of_month == 1
      assert Decimal.equal?(reloaded.amount, "-1.00")
    end
  end

  describe "resync_item/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "forces an update and resets manually_edited to false" do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-20],
        amount: "-99.00"
      })

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          manually_edited: true
        })

      assert {:ok, updated} = Forecast.resync_item(item)
      assert updated.day_of_month == 10
      assert Decimal.equal?(updated.amount, "-99.00")
      assert updated.manually_edited == false
    end

    test "returns an error when there isn't enough history" do
      item = recurring_item_fixture()
      assert Forecast.resync_item(item) == {:error, :insufficient_history}
    end
  end

  describe "manual_update/2" do
    test "updates the fields and marks manually_edited" do
      item = recurring_item_fixture(%{day_of_month: 5, amount: "-10.00"})

      assert {:ok, updated} =
               Forecast.manual_update(item, %{"day_of_month" => "20", "amount" => "-15.00"})

      assert updated.day_of_month == 20
      assert Decimal.equal?(updated.amount, "-15.00")
      assert updated.manually_edited == true
    end

    test "returns an error changeset for an invalid day" do
      item = recurring_item_fixture()
      assert {:error, changeset} = Forecast.manual_update(item, %{"day_of_month" => "40"})
      assert "must be less than or equal to 31" in errors_on(changeset).day_of_month
    end
  end

  describe "toggle_active/1" do
    test "flips active from true to false and back" do
      item = recurring_item_fixture(%{active: true})

      assert {:ok, %{active: false} = toggled} = Forecast.toggle_active(item)
      assert {:ok, %{active: true}} = Forecast.toggle_active(toggled)
    end
  end
end
