defmodule CashLens.Accounting.BalanceAdjusterTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Accounting.BalanceAdjuster
  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  defp user, do: CashLens.Repo.get!(CashLens.Users.User, CashLens.Repo.current_user_id())

  setup do
    today = Date.utc_today()
    account = account_fixture(%{balance: "100.00"})

    %{account: account, year: today.year, month: today.month}
  end

  defp seed_balance(account, year, month, final_balance) do
    balance_fixture(%{
      account_id: account.id,
      year: year,
      month: month,
      initial_balance: "0.00",
      income: "0.00",
      expenses: "0.00",
      balance: final_balance,
      final_balance: final_balance
    })
  end

  describe "current_final_balance/3" do
    test "returns the stored final balance", %{account: account, year: year, month: month} do
      seed_balance(account, year, month, "120.50")

      assert Decimal.equal?(
               BalanceAdjuster.current_final_balance(user(), account.id, year, month),
               Decimal.new("120.50")
             )
    end

    test "returns nil when there is no balance for the period", %{
      account: account,
      year: year,
      month: month
    } do
      refute BalanceAdjuster.current_final_balance(user(), account.id, year, month)
    end
  end

  describe "adjust_final_balance/5" do
    test "fails when the period has no calculated balance", %{
      account: account,
      year: year,
      month: month
    } do
      assert {:error, :balance_not_found} =
               BalanceAdjuster.adjust_final_balance(
                 user(),
                 account.id,
                 year,
                 month,
                 Decimal.new("10.00"),
                 :rendimento
               )
    end

    test "fails when the real balance already matches", %{
      account: account,
      year: year,
      month: month
    } do
      seed_balance(account, year, month, "120.50")

      assert {:error, :no_difference} =
               BalanceAdjuster.adjust_final_balance(
                 user(),
                 account.id,
                 year,
                 month,
                 Decimal.new("120.50"),
                 :rendimento
               )
    end

    test "fails when the rendimento category is missing", %{
      account: account,
      year: year,
      month: month
    } do
      seed_balance(account, year, month, "120.50")

      assert {:error, :category_not_found} =
               BalanceAdjuster.adjust_final_balance(
                 user(),
                 account.id,
                 year,
                 month,
                 Decimal.new("150.50"),
                 :rendimento
               )
    end

    defp adjust_rendimento(account, year, month) do
      BalanceAdjuster.adjust_final_balance(
        user(),
        account.id,
        year,
        month,
        Decimal.new("150.50"),
        :rendimento
      )
    end

    defp rendimento_date(account) do
      Repo.get_by!(Transaction, account_id: account.id, description: "Rendimento").date
    end

    defp manual_transaction(account, date, description) do
      {:ok, %Transaction{}} =
        Transactions.create_transaction(user(), %{
          account_id: account.id,
          date: date,
          description: description,
          amount: Decimal.new("-1.00"),
          source: "manual"
        })
    end

    test "books the difference as income in the rendimento category", %{
      account: account,
      year: year,
      month: month
    } do
      category = category_fixture(%{name: "Rendimento"})
      seed_balance(account, year, month, "120.50")

      assert {:ok, :rendimento} = adjust_rendimento(account, year, month)

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "Rendimento")

      assert Decimal.equal?(transaction.amount, Decimal.new("30.00"))
      assert transaction.category_id == category.id
    end

    test "running month without transactions is dated today", %{
      account: account,
      year: year,
      month: month
    } do
      category_fixture(%{name: "Rendimento"})
      seed_balance(account, year, month, "120.50")

      assert {:ok, :rendimento} = adjust_rendimento(account, year, month)
      assert rendimento_date(account) == Date.utc_today()
    end

    test "running month is dated at the last transaction on or before today", %{
      account: account,
      year: year,
      month: month
    } do
      category_fixture(%{name: "Rendimento"})
      today = Date.utc_today()
      first = Date.new!(year, month, 1)
      last = Date.end_of_month(first)

      manual_transaction(account, first, "Early")
      manual_transaction(account, last, "Month end")

      assert {:ok, :rendimento} = adjust_rendimento(account, year, month)

      # The month-end row is a future row unless today is the last day of the month.
      expected = if Date.compare(last, today) == :gt, do: first, else: last
      assert rendimento_date(account) == expected
      refute Date.after?(rendimento_date(account), today)
    end

    test "past month without transactions is dated at its last day", %{account: account} do
      category_fixture(%{name: "Rendimento"})
      seed_balance(account, 2020, 2, "120.50")

      assert {:ok, :rendimento} = adjust_rendimento(account, 2020, 2)
      assert rendimento_date(account) == ~D[2020-02-29]
    end

    test "past month is dated at that month's last transaction, not a later month's", %{
      account: account
    } do
      category_fixture(%{name: "Rendimento"})
      manual_transaction(account, ~D[2020-02-10], "In month")
      manual_transaction(account, ~D[2020-03-05], "Later month")
      manual_transaction(account, ~D[2020-01-20], "Earlier month")

      assert {:ok, :rendimento} = adjust_rendimento(account, 2020, 2)
      assert rendimento_date(account) == ~D[2020-02-10]
    end

    test "reports a duplicate instead of booking the same income twice", %{
      account: account,
      year: year,
      month: month
    } do
      category_fixture(%{name: "Rendimento"})
      seed_balance(account, year, month, "120.50")

      assert {:ok, :rendimento} = adjust_rendimento(account, year, month)

      current = BalanceAdjuster.current_final_balance(user(), account.id, year, month)

      assert {:error, :duplicate} =
               BalanceAdjuster.adjust_final_balance(
                 user(),
                 account.id,
                 year,
                 month,
                 Decimal.add(current, Decimal.new("30.00")),
                 :rendimento
               )
    end

    test "correcao shifts the account opening balance and rebuilds the chain", %{
      account: account,
      year: year,
      month: month
    } do
      seed_balance(account, year, month, "120.50")

      assert {:ok, :correcao} =
               BalanceAdjuster.adjust_final_balance(
                 user(),
                 account.id,
                 year,
                 month,
                 Decimal.new("150.50"),
                 :correcao
               )

      updated = Accounts.get_account!(CashLens.Ownership.current_user!(), account.id)
      assert Decimal.equal?(updated.balance, Decimal.new("130.00"))
    end
  end
end
