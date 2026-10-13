defmodule CashLens.AccountsTest do
  use CashLens.DataCase, async: false

  setup %{current_user_id: user_id} do
    {:ok, user: CashLens.Repo.get!(CashLens.Users.User, user_id)}
  end

  alias CashLens.Accounts

  describe "accounts" do
    alias CashLens.Accounts.Account

    import CashLens.AccountsFixtures

    @invalid_attrs %{name: nil, balance: nil, color: nil, bank: nil, icon: nil}

    test "list_accounts/0 returns all accounts", %{user: user} do
      account = account_fixture()
      assert Accounts.list_accounts(user) == [account]
    end

    test "list_accounts/1 can leave closed accounts out", %{user: user} do
      open_account = account_fixture()
      closed = account_fixture(%{is_closed: true})

      assert Accounts.list_accounts(user) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([open_account.id, closed.id])

      assert Accounts.list_accounts(user, include_closed: false) == [open_account]
    end

    test "list_bank_accounts/1 returns only non credit-card accounts, closed ones optional", %{
      user: user
    } do
      bank = account_fixture(%{name: "A bank", is_credit_card: false})
      closed_bank = account_fixture(%{name: "B bank", is_credit_card: false, is_closed: true})
      _card = account_fixture(%{is_credit_card: true})

      assert Accounts.list_bank_accounts(user, include_closed: false) == [bank]
      assert Accounts.list_bank_accounts(user) == [bank, closed_bank]
    end

    test "list_credit_cards/1 returns only credit-card accounts, closed ones optional", %{
      user: user
    } do
      card = account_fixture(%{name: "A card", is_credit_card: true})
      closed_card = account_fixture(%{name: "B card", is_credit_card: true, is_closed: true})
      _bank = account_fixture(%{is_credit_card: false})

      assert Accounts.list_credit_cards(user, include_closed: false) == [card]
      assert Accounts.list_credit_cards(user) == [card, closed_card]
    end

    test "get_account!/1 returns the account with given id", %{user: user} do
      account = account_fixture()
      assert Accounts.get_account!(user, account.id) == account
    end

    test "create_account/1 with valid data creates a account", %{user: user} do
      valid_attrs = %{
        name: "some name",
        balance: "120.5",
        color: "some color",
        bank: "some bank",
        icon: "some icon"
      }

      assert {:ok, %Account{} = account} = Accounts.create_account(user, valid_attrs)
      assert account.name == "some name"
      assert account.balance == Decimal.new("120.5")
      assert account.color == "some color"
      assert account.bank == "some bank"
      assert account.icon == "some icon"
    end

    test "create_account/1 with invalid data returns error changeset", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_account(user, @invalid_attrs)
    end

    test "update_account/2 with valid data updates the account", %{user: user} do
      account = account_fixture()

      update_attrs = %{
        name: "some updated name",
        balance: "456.7",
        color: "some updated color",
        bank: "some updated bank",
        icon: "some updated icon"
      }

      assert {:ok, %Account{} = account} = Accounts.update_account(user, account, update_attrs)
      assert account.name == "some updated name"
      assert account.balance == Decimal.new("456.7")
      assert account.color == "some updated color"
      assert account.bank == "some updated bank"
      assert account.icon == "some updated icon"
    end

    test "update_account/2 with invalid data returns error changeset", %{user: user} do
      account = account_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_account(user, account, @invalid_attrs)
      assert account == Accounts.get_account!(user, account.id)
    end

    test "delete_account/1 deletes the account", %{user: user} do
      account = account_fixture()
      assert {:ok, %Account{}} = Accounts.delete_account(user, account)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_account!(user, account.id) end
    end

    test "change_account/1 returns a account changeset", %{user: user} do
      account = account_fixture()
      assert %Ecto.Changeset{} = Accounts.change_account(account)
    end

    test "get_total_balance/0 returns the sum of all account balances", %{user: user} do
      assert Accounts.get_total_balance(user) == Decimal.new("0")
      account_fixture(balance: "100.50")
      account_fixture(balance: "200.25")
      assert Accounts.get_total_balance(user) == Decimal.new("300.75")
    end

    test "get_account_by_name/1 returns the account with given name", %{user: user} do
      account = account_fixture(name: "Unique Name")
      assert Accounts.get_account_by_name(user, "Unique Name") == account
      assert Accounts.get_account_by_name(user, "Non-existent") == nil
    end

    test "get_accounts_by_names/1 returns a name-keyed map for matching accounts", %{user: user} do
      a1 = account_fixture(name: "Alpha")
      a2 = account_fixture(name: "Beta")
      _other = account_fixture(name: "Gamma")

      result = Accounts.get_accounts_by_names(user, ["Alpha", "Beta", "Missing"])

      assert result["Alpha"] == a1
      assert result["Beta"] == a2
      refute Map.has_key?(result, "Missing")
      refute Map.has_key?(result, "Gamma")
    end

    test "changeset accepts closing_day/due_day and validates range", %{user: user} do
      valid =
        Account.changeset(%Account{}, %{
          name: "C",
          bank: "B",
          balance: 0,
          accepts_import: true,
          is_closed: false,
          is_credit_card: true,
          closing_day: 3,
          due_day: 10
        })

      assert valid.valid?

      invalid =
        Account.changeset(%Account{}, %{
          name: "C",
          bank: "B",
          balance: 0,
          accepts_import: true,
          is_closed: false,
          closing_day: 0,
          due_day: 40
        })

      refute invalid.valid?
    end
  end

  describe "find_accounts_by_bank_and_name/2" do
    import CashLens.AccountsFixtures

    test "matches case-insensitively on bank and name", %{user: user} do
      account =
        account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      assert [found] =
               Accounts.find_accounts_by_bank_and_name(user, "banco do brasil", "conta corrente")

      assert found.id == account.id
    end

    test "returns empty list when nothing matches", %{user: user} do
      assert [] = Accounts.find_accounts_by_bank_and_name(user, "Inexistente", "Nada")
    end

    test "returns all matches when ambiguous (same bank + name)", %{user: user} do
      account_fixture(bank: "Banco X", name: "Conta Corrente")
      account_fixture(bank: "Banco X", name: "Conta Corrente")

      assert length(Accounts.find_accounts_by_bank_and_name(user, "Banco X", "Conta Corrente")) ==
               2
    end
  end

  describe "display order" do
    import CashLens.AccountsFixtures

    test "accounts come back in the order they were arranged", %{user: user} do
      # Alphabetical on purpose, so a list that merely looks sorted is not
      # mistaken for one that is ordered.
      a = account_fixture(%{name: "Alfa"})
      b = account_fixture(%{name: "Bravo"})
      c = account_fixture(%{name: "Charlie"})

      :ok = Accounts.reorder_accounts(user, [c.id, a.id, b.id])

      assert Enum.map(Accounts.list_accounts(user), & &1.name) == ["Charlie", "Alfa", "Bravo"]

      assert Enum.map(Accounts.list_bank_accounts(user), & &1.name) == [
               "Charlie",
               "Alfa",
               "Bravo"
             ]
    end

    test "an account never placed sorts behind the arranged ones, by name", %{user: user} do
      placed = account_fixture(%{name: "Zulu"})
      account_fixture(%{name: "Mike"})
      account_fixture(%{name: "Bravo"})

      :ok = Accounts.reorder_accounts(user, [placed.id])

      assert Enum.map(Accounts.list_accounts(user), & &1.name) == ["Zulu", "Bravo", "Mike"]
    end

    test "cards are ordered the same way, and apart from the bank accounts", %{user: user} do
      card = account_fixture(%{name: "Zulu", is_credit_card: true})
      other_card = account_fixture(%{name: "Alfa", is_credit_card: true})

      :ok = Accounts.reorder_accounts(user, [card.id, other_card.id])

      assert Enum.map(Accounts.list_credit_cards(user), & &1.name) == ["Zulu", "Alfa"]
    end
  end

  describe "move/3" do
    setup do
      %{accounts: Enum.map(["a", "b", "c"], &%{id: &1})}
    end

    test "moves one place towards the top", %{accounts: accounts} do
      assert Enum.map(Accounts.move(accounts, "c", :up), & &1.id) == ["a", "c", "b"]
    end

    test "moves one place towards the bottom", %{accounts: accounts} do
      assert Enum.map(Accounts.move(accounts, "a", :down), & &1.id) == ["b", "a", "c"]
    end

    # A button at either end is a no-op, not an error: the screen keeps both
    # buttons in place rather than making the card's controls move as it moves.
    test "the first account cannot go up", %{accounts: accounts} do
      assert Accounts.move(accounts, "a", :up) == accounts
    end

    test "the last account cannot go down", %{accounts: accounts} do
      assert Accounts.move(accounts, "c", :down) == accounts
    end

    test "an id that is not in the list changes nothing", %{accounts: accounts} do
      assert Accounts.move(accounts, "zzz", :up) == accounts
    end
  end

  describe "the investment flag" do
    import CashLens.AccountsFixtures

    test "is a label: it changes no balance and no total", %{user: user} do
      account = account_fixture(%{name: "Tesouro", balance: "5000.00", is_investment: true})

      assert account.is_investment
      # Still a bank account, still listed, still carrying its balance.
      assert account.id in Enum.map(Accounts.list_bank_accounts(user), & &1.id)
      assert Decimal.equal?(account.balance, Decimal.new("5000.00"))
    end

    test "defaults to false", %{user: user} do
      refute account_fixture().is_investment
    end
  end
end
