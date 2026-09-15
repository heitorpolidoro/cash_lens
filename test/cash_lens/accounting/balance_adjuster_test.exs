defmodule CashLens.Accounting.BalanceAdjusterTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Accounting.BalanceAdjuster
  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

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
               BalanceAdjuster.current_final_balance(account.id, year, month),
               Decimal.new("120.50")
             )
    end

    test "returns nil when there is no balance for the period", %{
      account: account,
      year: year,
      month: month
    } do
      refute BalanceAdjuster.current_final_balance(account.id, year, month)
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
                 account.id,
                 year,
                 month,
                 Decimal.new("150.50"),
                 :rendimento
               )
    end

    test "books the difference as income on the last day of the month", %{
      account: account,
      year: year,
      month: month
    } do
      category = category_fixture(%{name: "Rendimento"})
      seed_balance(account, year, month, "120.50")

      assert {:ok, :rendimento} =
               BalanceAdjuster.adjust_final_balance(
                 account.id,
                 year,
                 month,
                 Decimal.new("150.50"),
                 :rendimento
               )

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "Rendimento")

      assert Decimal.equal?(transaction.amount, Decimal.new("30.00"))
      assert transaction.category_id == category.id
      assert transaction.date == Date.end_of_month(Date.new!(year, month, 1))
    end

    test "reports a duplicate instead of booking the same income twice", %{
      account: account,
      year: year,
      month: month
    } do
      category = category_fixture(%{name: "Rendimento"})
      last_day = Date.end_of_month(Date.new!(year, month, 1))

      {:ok, %Transaction{}} =
        Transactions.create_transaction(%{
          account_id: account.id,
          date: last_day,
          description: "Rendimento",
          amount: Decimal.new("30.00"),
          category_id: category.id
        })

      current = BalanceAdjuster.current_final_balance(account.id, year, month)

      assert {:error, :duplicate} =
               BalanceAdjuster.adjust_final_balance(
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
                 account.id,
                 year,
                 month,
                 Decimal.new("150.50"),
                 :correcao
               )

      updated = Accounts.get_account!(account.id)
      assert Decimal.equal?(updated.balance, Decimal.new("130.00"))
    end
  end
end
