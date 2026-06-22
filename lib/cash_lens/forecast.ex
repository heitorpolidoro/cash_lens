defmodule CashLens.Forecast do
  @moduledoc """
  The Forecast context: recurring fixed bills/income detected from
  transaction history, and the cash-flow projection built from them.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo
  alias CashLens.Forecast.RecurringItem
  alias CashLens.Accounts.Account
  alias CashLens.Categories.Category
  alias CashLens.Transactions.Transaction

  @history_months 6
  @min_occurrences 2

  @doc """
  Creates a recurring item directly. Used both by fixtures/tests and by
  the detection sync (Task 2) when a fixed category has no item yet.
  """
  def create_recurring_item(attrs) do
    %RecurringItem{}
    |> RecurringItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Derives a {day_of_month, amount} suggestion for a fixed category from its
  transaction history (non-credit-card accounts only, last 6 months).
  Returns `:insufficient_history` when fewer than 2 occurrences exist.
  """
  def suggest_for_category(%Category{} = category) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    rows =
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.category_id == ^category.id and a.is_credit_card == false and
            t.date >= ^since,
        select: %{date: t.date, amount: t.amount}
      )
      |> Repo.all()

    if length(rows) < @min_occurrences do
      :insufficient_history
    else
      days = rows |> Enum.map(& &1.date.day) |> Enum.sort()
      latest = Enum.max_by(rows, & &1.date, Date)
      {:ok, %{"day_of_month" => median(days), "amount" => latest.amount}}
    end
  end

  defp median(sorted_list) do
    Enum.at(sorted_list, div(length(sorted_list) - 1, 2))
  end
end
