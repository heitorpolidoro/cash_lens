defmodule CashLens.AccountsTest do
  use CashLens.DataCase, async: false

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

    test "get_accounts_by_names/1 returns a name-keyed map for matching accounts" do
      a1 = account_fixture(name: "Alpha")
      a2 = account_fixture(name: "Beta")
      _other = account_fixture(name: "Gamma")

      result = Accounts.get_accounts_by_names(["Alpha", "Beta", "Missing"])

      assert result["Alpha"] == a1
      assert result["Beta"] == a2
      refute Map.has_key?(result, "Missing")
      refute Map.has_key?(result, "Gamma")
    end
  end

  describe "find_accounts_by_bank_and_name/2" do
    import CashLens.AccountsFixtures

    test "matches case-insensitively on bank and name" do
      account =
        account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      assert [found] =
               Accounts.find_accounts_by_bank_and_name("banco do brasil", "conta corrente")

      assert found.id == account.id
    end

    test "returns empty list when nothing matches" do
      assert [] = Accounts.find_accounts_by_bank_and_name("Inexistente", "Nada")
    end

    test "returns all matches when ambiguous (same bank + name)" do
      account_fixture(bank: "Banco X", name: "Conta Corrente")
      account_fixture(bank: "Banco X", name: "Conta Corrente")

      assert length(Accounts.find_accounts_by_bank_and_name("Banco X", "Conta Corrente")) == 2
    end
  end
end
