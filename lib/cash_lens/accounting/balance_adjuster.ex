defmodule CashLens.Accounting.BalanceAdjuster do
  @moduledoc """
  Reconciles a calculated monthly balance against the balance the bank actually reports.

  The chained balance model (`CashLens.Accounting`) derives every month from the previous
  one, so a single missing movement — typically a savings yield that never shows up as a
  statement line — drifts every later month by the same amount. This module closes that
  gap in the two ways that make accounting sense:

    * `:rendimento` — the difference is genuine money earned during the month, so it is
      booked as an income transaction in the "rendimento" category dated the account's
      last transaction inside that month and on or before today (see `income_date/3`).
    * `:correcao` — the difference comes from a wrong opening balance, so the account's
      seed balance is shifted and the whole historical chain is rebuilt.

  Both branches leave the balance chain consistent: creating a transaction rebuilds the
  account's balances, and the correction path rebuilds them explicitly.
  """

  import Ecto.Query, warn: false

  alias CashLens.Accounting
  alias CashLens.Accounting.Balance
  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions

  @income_category_slug "rendimento"
  @income_description "Rendimento"

  @type adjust_type :: :rendimento | :correcao

  @type result ::
          {:ok, adjust_type()}
          | {:error,
             :balance_not_found | :category_not_found | :duplicate | :no_difference | term()}

  @doc """
  Adjusts the final balance of `account_id` for `year`/`month` so it matches `real_balance`.

  Returns `{:ok, type}` when an adjustment was applied, `{:error, :no_difference}` when the
  calculated balance already matches, and `{:error, reason}` otherwise.
  """
  @spec adjust_final_balance(
          Ecto.UUID.t(),
          integer(),
          integer(),
          Decimal.t(),
          adjust_type()
        ) :: result()
  def adjust_final_balance(account_id, year, month, real_balance, type) do
    case current_final_balance(account_id, year, month) do
      nil ->
        {:error, :balance_not_found}

      current ->
        real_balance
        |> Decimal.sub(current)
        |> apply_difference(account_id, year, month, type)
    end
  end

  @doc """
  Returns the currently calculated final balance for the given account and period.
  """
  @spec current_final_balance(Ecto.UUID.t(), integer(), integer()) :: Decimal.t() | nil
  def current_final_balance(account_id, year, month) do
    Balance
    |> where([b], b.account_id == ^account_id and b.year == ^year and b.month == ^month)
    |> select([b], b.final_balance)
    |> Repo.one()
  end

  defp apply_difference(diff, account_id, year, month, type) do
    if Decimal.equal?(diff, Decimal.new(0)) do
      {:error, :no_difference}
    else
      apply_adjustment(type, account_id, year, month, diff)
    end
  end

  defp apply_adjustment(:rendimento, account_id, year, month, diff) do
    @income_category_slug
    |> Categories.get_category_by_slug()
    |> create_income_transaction(account_id, year, month, diff)
  end

  defp apply_adjustment(:correcao, account_id, _year, _month, diff) do
    account = Accounts.get_account!(account_id)
    new_balance = Decimal.add(account.balance || Decimal.new(0), diff)

    case Accounts.update_account(account, %{balance: new_balance}) do
      {:ok, _account} ->
        Accounting.rebuild_account_balances(account_id)
        {:ok, :correcao}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp create_income_transaction(nil, _account_id, _year, _month, _diff),
    do: {:error, :category_not_found}

  defp create_income_transaction(category, account_id, year, month, diff) do
    attrs = %{
      account_id: account_id,
      date: income_date(account_id, year, month),
      description: @income_description,
      amount: diff,
      category_id: category.id
    }

    case Transactions.create_transaction(attrs) do
      {:ok, :duplicate} -> {:error, :duplicate}
      {:ok, _transaction} -> {:ok, :rendimento}
      {:error, reason} -> {:error, reason}
    end
  end

  # The account's last file/manual transaction inside the month, never after today, so the
  # income never lands in the future. Without one: the month's last day for a past month,
  # today for the running month.
  defp income_date(account_id, year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    today = Date.utc_today()

    if Date.after?(first, today) do
      # A month that has not started yet keeps the historical month-end date.
      last
    else
      upper = Enum.min([last, today], Date)
      Transactions.latest_transaction_date_between(account_id, first, upper) || upper
    end
  end
end
