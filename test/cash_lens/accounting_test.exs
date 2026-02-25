defmodule CashLens.AccountingTest do
  use CashLens.DataCase

  alias CashLens.Accounting

  describe "balances" do
    alias CashLens.Accounting.Balance

    import CashLens.AccountingFixtures

    @invalid_attrs %{balance: nil, month: nil, year: nil, initial_balance: nil, income: nil, expenses: nil, final_balance: nil}

    test "list_balances/0 returns all balances" do
      balance = balance_fixture()
      assert Accounting.list_balances() == [balance]
    end

    test "get_balance!/1 returns the balance with given id" do
      balance = balance_fixture()
      assert Accounting.get_balance!(balance.id) == balance
    end

    test "create_balance/1 with valid data creates a balance" do
      valid_attrs = %{balance: "120.5", month: 42, year: 42, initial_balance: "120.5", income: "120.5", expenses: "120.5", final_balance: "120.5"}

      assert {:ok, %Balance{} = balance} = Accounting.create_balance(valid_attrs)
      assert balance.balance == Decimal.new("120.5")
      assert balance.month == 42
      assert balance.year == 42
      assert balance.initial_balance == Decimal.new("120.5")
      assert balance.income == Decimal.new("120.5")
      assert balance.expenses == Decimal.new("120.5")
      assert balance.final_balance == Decimal.new("120.5")
    end

    test "create_balance/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounting.create_balance(@invalid_attrs)
    end

    test "update_balance/2 with valid data updates the balance" do
      balance = balance_fixture()
      update_attrs = %{balance: "456.7", month: 43, year: 43, initial_balance: "456.7", income: "456.7", expenses: "456.7", final_balance: "456.7"}

      assert {:ok, %Balance{} = balance} = Accounting.update_balance(balance, update_attrs)
      assert balance.balance == Decimal.new("456.7")
      assert balance.month == 43
      assert balance.year == 43
      assert balance.initial_balance == Decimal.new("456.7")
      assert balance.income == Decimal.new("456.7")
      assert balance.expenses == Decimal.new("456.7")
      assert balance.final_balance == Decimal.new("456.7")
    end

    test "update_balance/2 with invalid data returns error changeset" do
      balance = balance_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounting.update_balance(balance, @invalid_attrs)
      assert balance == Accounting.get_balance!(balance.id)
    end

    test "delete_balance/1 deletes the balance" do
      balance = balance_fixture()
      assert {:ok, %Balance{}} = Accounting.delete_balance(balance)
      assert_raise Ecto.NoResultsError, fn -> Accounting.get_balance!(balance.id) end
    end

    test "change_balance/1 returns a balance changeset" do
      balance = balance_fixture()
      assert %Ecto.Changeset{} = Accounting.change_balance(balance)
    end
  end
end
