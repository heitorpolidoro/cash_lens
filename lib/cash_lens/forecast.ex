defmodule CashLens.Forecast do
  @moduledoc """
  The Forecast context: recurring fixed bills/income detected from
  transaction history, and the cash-flow projection built from them.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo
  alias CashLens.Forecast.RecurringItem
  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.Transactions.Transaction
  alias CashLens.Accounting
  alias CashLens.Accounts

  @history_months 6
  @min_occurrences 2
  @default_horizon_days 90

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

  @doc """
  Lists all recurring items ordered by day_of_month.
  """
  def list_recurring_items do
    RecurringItem
    |> order_by([r], asc: r.day_of_month)
    |> Repo.all()
  end

  @doc """
  Gets a single recurring item by id.
  """
  def get_recurring_item!(id), do: Repo.get!(RecurringItem, id)

  @doc """
  Syncs all fixed categories against recurring_items: creates items for
  fixed categories that don't have one yet, and refreshes day/amount for
  existing items that haven't been manually edited.
  """
  def sync_all do
    fixed_categories = Categories.list_categories() |> Enum.filter(&(&1.type == "fixed"))
    existing_by_category = Map.new(list_recurring_items(), &{&1.category_id, &1})

    Enum.reduce(fixed_categories, %{created: 0, updated: 0}, fn category, acc ->
      sync_one(category, Map.get(existing_by_category, category.id), acc)
    end)
  end

  defp sync_one(_category, %RecurringItem{manually_edited: true}, acc), do: acc

  defp sync_one(category, nil, acc) do
    case suggest_for_category(category) do
      {:ok, suggestion} ->
        {:ok, _} =
          create_recurring_item(
            Map.merge(suggestion, %{"category_id" => category.id, "label" => category.name})
          )

        %{acc | created: acc.created + 1}

      :insufficient_history ->
        acc
    end
  end

  defp sync_one(category, %RecurringItem{} = item, acc) do
    case suggest_for_category(category) do
      {:ok, suggestion} ->
        {:ok, _} = item |> RecurringItem.changeset(suggestion) |> Repo.update()
        %{acc | updated: acc.updated + 1}

      :insufficient_history ->
        acc
    end
  end

  @doc """
  Forces a single item to re-derive day_of_month/amount from history and
  resets manually_edited to false.
  """
  def resync_item(%RecurringItem{} = item) do
    category = Categories.get_category!(item.category_id)

    case suggest_for_category(category) do
      {:ok, suggestion} ->
        item
        |> RecurringItem.changeset(Map.put(suggestion, "manually_edited", false))
        |> Repo.update()

      :insufficient_history ->
        {:error, :insufficient_history}
    end
  end

  @doc """
  Updates day_of_month and/or amount from the UI. Marks the item as
  manually_edited so future sync_all/0 calls leave it untouched.
  """
  def manual_update(%RecurringItem{} = item, attrs) do
    item
    |> RecurringItem.changeset(Map.put(attrs, "manually_edited", true))
    |> Repo.update()
  end

  def toggle_active(%RecurringItem{} = item) do
    item
    |> RecurringItem.changeset(%{"active" => !item.active})
    |> Repo.update()
  end

  defp median(sorted_list) do
    Enum.at(sorted_list, div(length(sorted_list) - 1, 2))
  end

  @doc """
  Projects the cash flow of non-credit-card accounts forward from today,
  applying every active recurring item's future occurrences within
  `horizon_days`.
  """
  def project(horizon_days \\ @default_horizon_days) do
    starting_balance = current_balance()
    today = Date.utc_today()
    horizon_end = Date.add(today, horizon_days)

    occurrences =
      list_recurring_items()
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(&future_occurrences(&1, today, horizon_end))
      |> Enum.sort_by(& &1.date, Date)
      |> with_running_balance(starting_balance)

    zero_date =
      occurrences
      |> Enum.find(&Decimal.negative?(&1.balance_after))
      |> case do
        nil -> nil
        occ -> occ.date
      end

    %{starting_balance: starting_balance, occurrences: occurrences, zero_date: zero_date}
  end

  @doc "Cumulative balance as of `date` (inclusive)."
  def balance_on(%{starting_balance: starting_balance, occurrences: occurrences}, date) do
    occurrences
    |> Enum.filter(&(Date.compare(&1.date, date) != :gt))
    |> List.last()
    |> case do
      nil -> starting_balance
      occ -> occ.balance_after
    end
  end

  @doc """
  Date of the next occurrence with a positive amount (income), or today + 30
  days when no income item is configured yet.
  """
  def next_income_date(%{occurrences: occurrences}) do
    occurrences
    |> Enum.find(&Decimal.positive?(&1.item.amount))
    |> case do
      nil -> Date.add(Date.utc_today(), 30)
      occ -> occ.date
    end
  end

  defp current_balance do
    balances_by_account =
      Map.new(Accounting.list_latest_balances(), &{&1.account_id, &1.final_balance})

    Accounts.list_accounts()
    |> Enum.reject(&(&1.is_closed or &1.is_credit_card))
    |> Enum.reduce(Decimal.new("0"), fn account, acc ->
      balance = Map.get(balances_by_account, account.id, account.balance)
      Decimal.add(acc, balance)
    end)
  end

  defp with_running_balance(occurrences, starting_balance) do
    {result, _final} =
      Enum.map_reduce(occurrences, starting_balance, fn occ, balance ->
        new_balance = Decimal.add(balance, occ.item.amount)
        {%{occ | balance_after: new_balance}, new_balance}
      end)

    result
  end

  defp future_occurrences(%RecurringItem{} = item, today, horizon_end) do
    first = next_occurrence_date(item.day_of_month, today)

    first
    |> Stream.iterate(&next_month_date(&1, item.day_of_month))
    |> Enum.take_while(&(Date.compare(&1, horizon_end) != :gt))
    |> Enum.map(&%{date: &1, item: item, balance_after: nil})
  end

  @doc false
  def next_occurrence_date(day_of_month, today) do
    this_month = clamp_day(today.year, today.month, day_of_month)

    if this_month.day >= today.day do
      this_month
    else
      next_month_date(today, day_of_month)
    end
  end

  defp next_month_date(date, day_of_month) do
    {year, month} = add_month(date.year, date.month)
    clamp_day(year, month, day_of_month)
  end

  defp add_month(year, 12), do: {year + 1, 1}
  defp add_month(year, month), do: {year, month + 1}

  defp clamp_day(year, month, day) do
    last_day = Date.new!(year, month, 1) |> Date.days_in_month()
    Date.new!(year, month, min(day, last_day))
  end
end
