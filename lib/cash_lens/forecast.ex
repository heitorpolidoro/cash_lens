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
  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
  alias CashLens.Installments

  @history_months 6
  @min_occurrences 2
  @default_horizon_days 365

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
    fixed_categories =
      Categories.list_categories()
      |> Enum.filter(&(&1.type == "fixed" and not credit_card_category?(&1)))

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

  defp credit_card_category?(%Category{slug: slug}) when is_binary(slug) do
    slug == "cartao-de-credito" or String.starts_with?(slug, "cartao-de-credito-")
  end

  defp credit_card_category?(_category), do: false

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

  def set_as_salary(%RecurringItem{} = item) do
    Repo.update_all(RecurringItem, set: [is_salary: false])
    item |> RecurringItem.changeset(%{"is_salary" => true}) |> Repo.update()
  end

  def unset_salary(%RecurringItem{} = item) do
    item |> RecurringItem.changeset(%{"is_salary" => false}) |> Repo.update()
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

    recurring_occurrences =
      list_recurring_items()
      |> Enum.filter(& &1.active)
      |> Enum.flat_map(&future_occurrences(&1, today, horizon_end))

    occurrences =
      (recurring_occurrences ++ card_occurrences(today, horizon_end))
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
  Date of the next occurrence of the salary item (is_salary: true).
  Falls back to today + 30 days when none is configured.
  """
  def next_income_date(%{occurrences: occurrences}) do
    occurrences
    |> Enum.find(& &1.item.is_salary)
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

  @doc """
  One outflow occurrence per credit-card account (with a configured
  closing_day/due_day) per due-month in [today, horizon_end]: the real
  unpaid boleto for that month if one was imported, otherwise an estimate
  from the account's most recent boleto (within @history_months) plus that
  month's known installments. Paid months and cycle-less accounts produce
  no occurrence.
  """
  def card_occurrences(today, horizon_end) do
    card_accounts()
    |> Enum.flat_map(&card_account_occurrences(&1, today, horizon_end))
  end

  defp card_accounts do
    Accounts.list_accounts()
    |> Enum.filter(fn a ->
      a.is_credit_card and not a.is_closed and is_integer(a.closing_day) and
        is_integer(a.due_day)
    end)
  end

  defp card_account_occurrences(account, today, horizon_end) do
    card_due_dates(account.due_day, today, horizon_end)
    |> Enum.map(&card_occurrence_for_date(account, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp card_due_dates(due_day, today, horizon_end) do
    next_occurrence_date(due_day, today)
    |> Stream.iterate(&next_month_date(&1, due_day))
    |> Enum.take_while(&(Date.compare(&1, horizon_end) != :gt))
  end

  defp card_occurrence_for_date(account, date) do
    month = Date.beginning_of_month(date)

    case statement_for_month(account.id, month) do
      %Statement{payment_transaction_id: nil} = s ->
        build_card_occurrence(account, s.due_date, statement_amount(s), :boleto)

      %Statement{} ->
        nil

      nil ->
        case estimate_for_month(account, month) do
          nil -> nil
          amount -> build_card_occurrence(account, date, amount, :estimado)
        end
    end
  end

  defp statement_for_month(account_id, month) do
    month_end = Date.end_of_month(month)

    from(s in Statement,
      where: s.account_id == ^account_id and s.due_date >= ^month and s.due_date <= ^month_end
    )
    |> Repo.one()
  end

  defp statement_amount(%Statement{total_a_pagar: total}) when not is_nil(total),
    do: Decimal.negate(total)

  defp statement_amount(%Statement{id: id}) do
    id
    |> CreditCards.statement_transactions()
    |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
  end

  defp estimate_for_month(account, month) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    recent =
      from(s in Statement,
        where: s.account_id == ^account.id and not is_nil(s.due_date) and s.due_date >= ^since,
        order_by: [desc: s.due_date],
        limit: 1
      )
      |> Repo.one()

    case recent do
      nil ->
        nil

      statement ->
        recent_month = Date.beginning_of_month(statement.due_date)
        recent_installments = Installments.account_installment_total(account.id, recent_month)
        variable = Decimal.add(statement_amount(statement), recent_installments)
        future_installments = Installments.account_installment_total(account.id, month)
        Decimal.sub(variable, future_installments)
    end
  end

  defp build_card_occurrence(account, date, amount, origin) do
    %{
      date: date,
      item: %{id: account.id, label: "Fatura #{account.name}", amount: amount, is_salary: false},
      balance_after: nil,
      origin: origin
    }
  end
end
