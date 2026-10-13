defmodule CashLens.AccountingTenancyTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Accounting
  alias CashLens.Accounting.Balance
  alias CashLens.Accounting.BalanceAdjuster
  alias CashLens.Accounts
  alias CashLens.Repo
  alias CashLens.Tenancy

  setup do
    %{a: a, b: b} = cross_tenant()
    account = account_fixture(%{user: a, name: "A account", balance: "100.00"})

    Tenancy.acting_as(a, fn ->
      transaction_fixture(%{
        user: a,
        account_id: account.id,
        amount: "50.00",
        date: ~D[2026-01-05]
      })

      {:ok, balance} = Accounting.calculate_monthly_balance(a, account.id, 2026, 1)
      {:ok, a: a, b: b, account: account, balance: balance}
    end)
  end

  defp as(user, fun), do: Tenancy.acting_as(user, fun)

  # A's persisted state, read as A.
  defp snapshot(a, account, balance) do
    as(a, fn ->
      {Repo.get!(Balance, balance.id), Accounts.get_account!(a, account.id),
       Repo.aggregate(Balance, :count)}
    end)
  end

  describe "user B cannot read user A's balances" do
    test "lists come back empty", %{b: b} do
      as(b, fn ->
        assert Accounting.list_balances(b) == []
        assert Accounting.list_latest_balances(b, heal: false) == []
        assert Accounting.get_historical_balances(b, heal: false) == []
        assert Accounting.get_historical_balances(b, limit: 12, heal: false) == []
      end)
    end

    test "healing for B does not touch A's accounts", %{a: a, b: b, account: account} do
      as(b, fn ->
        assert Accounting.list_latest_balances(b) == []
        assert Accounting.get_historical_balances(b) == []
      end)

      as(a, fn ->
        assert Accounting.list_balances(a, %{"account_id" => account.id}) != []
      end)
    end

    test "accounts passed by the caller are ignored when B does not own them", %{
      b: b,
      account: account
    } do
      as(b, fn ->
        assert Accounting.list_latest_balances(b, accounts: [account], heal: false) == []
      end)
    end

    test "A still sees their own rows", %{a: a, balance: balance} do
      as(a, fn ->
        ids = a |> Accounting.list_balances() |> Enum.map(& &1.id)
        assert balance.id in ids
        assert [%{account_id: account_id}] = Accounting.list_latest_balances(a, heal: false)
        assert account_id == balance.account_id
        assert Enum.any?(Accounting.get_historical_balances(a, heal: false), &(&1.year == 2026))
      end)
    end

    test "lookups return nil or raise", %{b: b, account: account, balance: balance} do
      as(b, fn ->
        assert_raise Ecto.NoResultsError, fn -> Accounting.get_balance!(b, balance.id) end
        assert Accounting.get_latest_balance_for_account(b, account.id) == nil
        assert Accounting.get_oldest_balance_for_account(b, account.id) == nil
        assert BalanceAdjuster.current_final_balance(b, account.id, 2026, 1) == nil
      end)
    end

    test "a filter on A's account id finds nothing", %{b: b, account: account} do
      as(b, fn ->
        assert Accounting.list_balances(b, %{"account_id" => account.id}) == []
      end)
    end
  end

  describe "user B cannot change user A's balances" do
    test "update and delete answer :not_found and leave the row unchanged", %{
      a: a,
      b: b,
      account: account,
      balance: balance
    } do
      before = snapshot(a, account, balance)

      as(b, fn ->
        assert {:error, :not_found} = Accounting.update_balance(b, balance, %{income: "999"})
        assert {:error, :not_found} = Accounting.delete_balance(b, balance)
      end)

      assert snapshot(a, account, balance) == before
    end

    test "calculate and rebuild answer :not_found and write nothing", %{
      a: a,
      b: b,
      account: account,
      balance: balance
    } do
      before = snapshot(a, account, balance)

      as(b, fn ->
        assert {:error, :not_found} = Accounting.calculate_monthly_balance(b, account.id, 2026, 1)
        assert {:error, :not_found} = Accounting.calculate_monthly_balance(b, account.id, 2026, 2)
        assert {:error, :not_found} = Accounting.rebuild_account_balances(b, account.id)
        assert :ok = Accounting.recalculate_all_balances(b)
      end)

      assert snapshot(a, account, balance) == before
    end

    test "the adjuster answers :not_found for A's account", %{
      a: a,
      b: b,
      account: account,
      balance: balance
    } do
      before = snapshot(a, account, balance)

      as(b, fn ->
        for type <- [:rendimento, :correcao] do
          assert {:error, :not_found} =
                   BalanceAdjuster.adjust_final_balance(
                     b,
                     account.id,
                     2026,
                     1,
                     Decimal.new("500"),
                     type
                   )
        end
      end)

      assert snapshot(a, account, balance) == before
    end

    test "creating a balance on A's account is a changeset error on account_id", %{
      b: b,
      account: account
    } do
      attrs = %{
        account_id: account.id,
        year: 2030,
        month: 1,
        initial_balance: "0",
        income: "0",
        expenses: "0",
        balance: "0",
        final_balance: "0"
      }

      as(b, fn ->
        assert {:error, changeset} = Accounting.create_balance(b, attrs)
        assert %{account_id: [_ | _]} = errors_on(changeset)
      end)
    end

    test "a user_id in attrs is ignored on create", %{a: a, b: b} do
      own = account_fixture(%{user: b, name: "B account"})

      as(b, fn ->
        {:ok, created} =
          Accounting.create_balance(b, %{
            "user_id" => a.id,
            "account_id" => own.id,
            "year" => 2030,
            "month" => 1,
            "initial_balance" => "0",
            "income" => "0",
            "expenses" => "0",
            "balance" => "0",
            "final_balance" => "0"
          })

        assert created.user_id == b.id
      end)
    end
  end

  describe "monthly totals" do
    test "B's total never includes A's transactions in the same month", %{
      a: a,
      b: b,
      account: a_account
    } do
      b_account = account_fixture(%{user: b, name: "B account", balance: "0"})

      transaction_fixture(%{
        user: b,
        account_id: b_account.id,
        amount: "7.00",
        date: ~D[2026-01-09]
      })

      as(b, fn ->
        assert {:ok, balance} = Accounting.calculate_monthly_balance(b, b_account.id, 2026, 1)
        assert Decimal.equal?(balance.income, "7.00")
        assert balance.user_id == b.id
      end)

      as(a, fn ->
        assert [january] =
                 Accounting.list_balances(a, %{
                   "account_id" => a_account.id,
                   "year" => "2026",
                   "month" => "1"
                 })

        assert Decimal.equal?(january.income, "50.00")
      end)
    end

    test "a category of B on A's transaction does not turn it into a transfer", %{
      a: a,
      b: b,
      account: account
    } do
      transfer = category_fixture(%{user: b, name: "transfer"})

      # A's transaction pointing at B's "transfer" category: the category is not
      # A's, so the join must not see it and the amount stays plain income.
      as(a, fn ->
        tx =
          transaction_fixture(%{
            user: a,
            account_id: account.id,
            amount: "10.00",
            date: ~D[2026-03-05]
          })

        Repo.update_all(
          from(t in CashLens.Transactions.Transaction, where: t.id == ^tx.id),
          set: [category_id: transfer.id]
        )

        assert {:ok, balance} = Accounting.calculate_monthly_balance(a, account.id, 2026, 3)
        assert Decimal.equal?(balance.income, "10.00")
        assert Decimal.equal?(balance.transfers_in, "0")
      end)
    end
  end
end
