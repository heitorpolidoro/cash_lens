defmodule CashLens.AccountsTenancyTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Accounts
  alias CashLens.Tenancy

  setup do
    %{a: a, b: b} = cross_tenant()
    account = account_fixture(%{user: a, name: "A account", is_credit_card: false})
    card = account_fixture(%{user: a, name: "A card", is_credit_card: true})
    {:ok, a: a, b: b, account: account, card: card}
  end

  defp as(user, fun), do: Tenancy.acting_as(user, fun)

  describe "user B cannot see user A's accounts" do
    test "list functions come back empty", %{b: b} do
      as(b, fn ->
        assert Accounts.list_accounts(b) == []
        assert Accounts.list_bank_accounts(b) == []
        assert Accounts.list_credit_cards(b) == []
        assert Accounts.list_active_accounts(b) == []
        assert Accounts.get_total_balance(b) == Decimal.new("0")
      end)
    end

    test "user A still sees their own rows", %{a: a, account: account, card: card} do
      as(a, fn ->
        assert Enum.sort(Enum.map(Accounts.list_accounts(a), & &1.id)) ==
                 Enum.sort([account.id, card.id])

        assert Accounts.list_bank_accounts(a) == [account]
        assert Accounts.list_credit_cards(a) == [card]
      end)
    end

    test "lookups return nil, raise or come back empty", %{b: b, account: account} do
      as(b, fn ->
        assert_raise Ecto.NoResultsError, fn -> Accounts.get_account!(b, account.id) end
        assert Accounts.get_account_by_name(b, account.name) == nil
        assert Accounts.get_accounts_by_names(b, [account.name]) == %{}
        assert Accounts.find_accounts_by_bank_and_name(b, account.bank, account.name) == []
      end)
    end
  end

  describe "user B cannot change user A's accounts" do
    test "update and delete answer :not_found and leave the row unchanged", %{
      a: a,
      b: b,
      account: account
    } do
      as(b, fn ->
        assert {:error, :not_found} = Accounts.update_account(b, account, %{name: "hijacked"})
        assert {:error, :not_found} = Accounts.delete_account(b, account)
      end)

      as(a, fn -> assert Accounts.get_account!(a, account.id) == account end)
    end

    test "reorder skips foreign ids", %{a: a, b: b, account: account, card: card} do
      as(a, fn -> :ok = Accounts.reorder_accounts(a, [account.id, card.id]) end)

      as(b, fn -> assert :ok = Accounts.reorder_accounts(b, [card.id, account.id]) end)

      as(a, fn ->
        assert Accounts.get_account!(a, account.id).position == 0
        assert Accounts.get_account!(a, card.id).position == 1
      end)
    end

    test "delete removes the owner's account", %{a: a, account: account} do
      as(a, fn ->
        assert {:ok, _} = Accounts.delete_account(a, account)
        assert_raise Ecto.NoResultsError, fn -> Accounts.get_account!(a, account.id) end
      end)
    end
  end

  describe "create_account/2" do
    test "sets the owner from the user and ignores a user_id in attrs", %{a: a, b: b} do
      as(b, fn ->
        assert {:ok, created} =
                 Accounts.create_account(b, %{
                   "name" => "mine",
                   "bank" => "bank",
                   "balance" => "1",
                   "color" => "c",
                   "icon" => "i",
                   "user_id" => a.id
                 })

        assert created.user_id == b.id
      end)
    end
  end
end
