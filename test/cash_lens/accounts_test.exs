defmodule CashLens.AccountsTest do
  use CashLens.DataCase

  alias CashLens.Accounts

  describe "accounts" do
    alias CashLens.Accounts.Account

    import CashLens.AccountsFixtures

    @invalid_attrs %{name: nil, balance: nil, color: nil, bank: nil, icon: nil}

    test "list_accounts/0 returns all accounts" do
      account = account_fixture()
      assert Accounts.list_accounts() == [account]
    end

    test "get_account!/1 returns the account with given id" do
      account = account_fixture()
      assert Accounts.get_account!(account.id) == account
    end

    test "create_account/1 with valid data creates a account" do
      valid_attrs = %{
        name: "some name",
        balance: "120.5",
        color: "some color",
        bank: "some bank",
        icon: "some icon"
      }

      assert {:ok, %Account{} = account} = Accounts.create_account(valid_attrs)
      assert account.name == "some name"
      assert account.balance == Decimal.new("120.5")
      assert account.color == "some color"
      assert account.bank == "some bank"
      assert account.icon == "some icon"
    end

    test "create_account/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_account(@invalid_attrs)
    end

    test "update_account/2 with valid data updates the account" do
      account = account_fixture()

      update_attrs = %{
        name: "some updated name",
        balance: "456.7",
        color: "some updated color",
        bank: "some updated bank",
        icon: "some updated icon"
      }

      assert {:ok, %Account{} = account} = Accounts.update_account(account, update_attrs)
      assert account.name == "some updated name"
      assert account.balance == Decimal.new("456.7")
      assert account.color == "some updated color"
      assert account.bank == "some updated bank"
      assert account.icon == "some updated icon"
    end

    test "update_account/2 with invalid data returns error changeset" do
      account = account_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_account(account, @invalid_attrs)
      assert account == Accounts.get_account!(account.id)
    end

    test "delete_account/1 deletes the account" do
      account = account_fixture()
      assert {:ok, %Account{}} = Accounts.delete_account(account)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_account!(account.id) end
    end

    test "change_account/1 returns a account changeset" do
      account = account_fixture()
      assert %Ecto.Changeset{} = Accounts.change_account(account)
    end

    test "get_total_balance/0 returns the sum of all account balances" do
      assert Accounts.get_total_balance() == Decimal.new("0")
      account_fixture(balance: "100.50")
      account_fixture(balance: "200.25")
      assert Accounts.get_total_balance() == Decimal.new("300.75")
    end

    test "get_account_by_name/1 returns the account with given name" do
      account = account_fixture(name: "Unique Name")
      assert Accounts.get_account_by_name("Unique Name") == account
      assert Accounts.get_account_by_name("Non-existent") == nil
    end
  end
end
