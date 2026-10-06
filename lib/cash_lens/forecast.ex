defmodule CashLens.Forecast do
  @moduledoc """
  The Forecast context: recurring fixed bills/income detected from
  transaction history, and the cash-flow projection built from them.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo
  alias CashLens.Forecast.RecurringItem
  alias CashLens.Accounts.Scopes
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
  @baseline_months 6

  # How many of a card's recent bills the estimate averages. Bounded so a card
  # with a long history is still projected from its current spending level.
  @estimate_sample 6

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
  transaction history (the `CashLens.Accounts.Scopes` cash-accounts scope only,
  last 6 months).
  Returns `:insufficient_history` when fewer than 2 occurrences exist.
  """
  def suggest_for_category(%Category{} = category) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    rows =
      from(t in Transaction,
        where: t.category_id == ^category.id and t.date >= ^since,
        select: %{date: t.date, amount: t.amount}
      )
      |> Scopes.cash_accounts_only()
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

  @doc """
  Deactivates recurring items whose whole category is already projected as an
  installment commitment, and returns the ones it switched off.

  The two projectors cannot see each other: a recurring item is bound to a
  *category* and never looks at transactions, while a commitment works from the
  transactions linked to it. Register a commitment for a category that
  `sync_all/0` had already turned into a recurring item and the same expense is
  charged twice, on top of a balance that no longer reconciles with anything.

  The test is deliberately strict: every transaction in the category must belong
  to a group, and there must be at least one. A category holding so much as one
  unlinked debit still has spending that only the recurring item accounts for, so
  it is left alone. Items edited by hand are never touched — the same rule
  `sync_all/0` follows.
  """
  def deactivate_superseded_items do
    superseded =
      list_recurring_items()
      |> Enum.filter(
        &(&1.active and not &1.manually_edited and fully_grouped_category?(&1.category_id))
      )

    Enum.each(superseded, fn item ->
      item
      |> Ecto.Changeset.change(%{active: false})
      |> Repo.update!()
    end)

    superseded
  end

  defp fully_grouped_category?(category_id) do
    counts =
      from(t in Transaction,
        where: t.category_id == ^category_id,
        select: %{
          total: count(t.id),
          grouped: count(t.installment_group_id)
        }
      )
      |> Repo.one()

    counts.total > 0 and counts.total == counts.grouped
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
      (recurring_occurrences ++
         card_occurrences(today, horizon_end) ++
         commitment_occurrences(today, horizon_end) ++
         variable_baseline(today, horizon_end))
      |> Enum.sort_by(& &1.date, Date)
      |> with_running_balance(starting_balance)

    # Running out of money is reaching zero, not passing it: a balance of
    # exactly 0,00 buys nothing, so it counts. The field is named for that.
    zero_date =
      occurrences
      |> Enum.find(&(Decimal.compare(&1.balance_after, 0) != :gt))
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
  The occurrences of `projection` settling within `days` days from today.

  The screen reads three different windows (30, 90 and the full horizon) out of
  the *same* projection: they are date slices, not separate projections.
  """
  def occurrences_within(%{occurrences: occurrences}, days) do
    limit = Date.add(Date.utc_today(), days)
    Enum.filter(occurrences, &(Date.compare(&1.date, limit) != :gt))
  end

  @doc """
  The occurrences the temporal ruler shows: everything settling within `days`
  days, minus the variable-spending baseline.

  The baseline is an average, not an event. Listing 365 identical cards would
  bury the real commitments it sits between, and there is no bill to go look at
  behind any one of them. It still shapes every balance on this list, because
  `with_running_balance/2` accumulates over the whole projection before anything
  is filtered out — so each commitment here carries a `balance_after` that
  already includes the daily drag.
  """
  def ruler_occurrences(projection, days) do
    projection
    |> occurrences_within(days)
    |> Enum.reject(& &1[:baseline])
  end

  @doc """
  The average variable spending of the last `@baseline_months` months.

  Returns the rate together with the arithmetic behind it -- `total` spent over
  `days` days, from `since` to `until` -- because a balance moved by a number
  nobody can derive is worse than no number: the screen shows the division, not
  just its result.

  Variable spending is what the projection's three event sources cannot see: an
  outflow from a cash account whose category is neither fixed (already a
  `RecurringItem`) nor credit-card (already a `card_occurrences/2` bill), and
  which is not a transfer between the user's own accounts. An uncategorized
  outflow counts — unfiled grocery money is still gone.

  Returns `nil` when the window holds no such spending, so a fresh database
  projects no baseline rather than a baseline of zero.
  """
  def variable_baseline_rate do
    today = Date.utc_today()
    days = 30 * @baseline_months
    since = Date.add(today, -days)
    total = variable_spending_total(since, Date.add(today, -1))

    if Decimal.equal?(total, 0) do
      nil
    else
      daily = total |> Decimal.div(days) |> Decimal.round(2)

      %{
        daily: daily,
        monthly: daily |> Decimal.mult(30) |> Decimal.round(2),
        months: @baseline_months,
        since: since,
        until: Date.add(today, -1),
        total: total,
        days: days
      }
    end
  end

  defp variable_spending_total(since, until) do
    fixed_category_ids =
      from(c in Category, where: c.type == "fixed", select: c.id)
      |> Repo.all()

    from(t in Transaction,
      left_join: c in Category,
      on: c.id == t.category_id,
      where: t.date >= ^since and t.date <= ^until,
      where: t.amount < 0,
      where: is_nil(t.transfer_key),
      where: is_nil(t.category_id) or t.category_id not in ^fixed_category_ids,
      where: is_nil(c.slug) or not like(c.slug, "cartao-de-credito%"),
      # A parcel of a registered commitment is projected explicitly, by
      # `commitment_occurrences/2` or inside a card's bill. Averaging it in here
      # as well would charge the same financing twice — once smeared across every
      # day of the month, once on its due date.
      where: is_nil(t.installment_group_id),
      select: sum(t.amount)
    )
    |> Scopes.cash_accounts_only()
    |> Repo.one()
    |> case do
      nil -> Decimal.new("0")
      total -> total
    end
  end

  # One occurrence per day, starting TOMORROW: today's variable spending is
  # already inside `current_balance/0`, so charging the average on top of it
  # would count the same day twice.
  defp variable_baseline(today, horizon_end) do
    case variable_baseline_rate() do
      nil ->
        []

      %{daily: daily} ->
        item = %{
          id: :variable_baseline,
          label: "Gasto variável (média)",
          amount: daily,
          is_salary: false
        }

        Date.range(Date.add(today, 1), horizon_end)
        |> Enum.map(&%{date: &1, item: item, balance_after: nil, baseline: true})
    end
  end

  @doc """
  The projected balance on every day from today through `days` days ahead,
  inclusive, as `[%{date: Date.t(), balance: Decimal.t()}]`.

  The balance only moves on a day something settles, so this is a step series:
  a day with no occurrence carries the previous day's balance, and a day with
  several carries the balance after the last of them.

  Built in one pass over the already-sorted occurrences rather than by calling
  `balance_on/2` per day, which would rescan the whole list for each of the
  366 days.
  """
  def daily_balances(%{starting_balance: starting_balance, occurrences: occurrences}, days) do
    today = Date.utc_today()

    {points, _remaining, _balance} =
      Enum.reduce(0..days, {[], occurrences, starting_balance}, fn offset,
                                                                   {acc, pending, balance} ->
        date = Date.add(today, offset)
        {settled, pending} = Enum.split_while(pending, &(Date.compare(&1.date, date) != :gt))

        balance =
          case List.last(settled) do
            nil -> balance
            occ -> occ.balance_after
          end

        {[%{date: date, balance: balance} | acc], pending, balance}
      end)

    Enum.reverse(points)
  end

  @doc """
  The occurrence leaving the lowest balance within `days` days, or `nil` when
  nothing settles in that window.
  """
  def minimum_point(projection, days) do
    projection
    |> occurrences_within(days)
    |> Enum.min_by(& &1.balance_after, &(Decimal.compare(&1, &2) != :gt), fn -> nil end)
  end

  @doc """
  The projected balance at the end of the projection's horizon: the balance
  after its last occurrence, or the starting balance when it has none.
  """
  def final_balance(%{starting_balance: starting_balance, occurrences: occurrences}) do
    case List.last(occurrences) do
      nil -> starting_balance
      occ -> occ.balance_after
    end
  end

  @doc """
  The lowest point the daily curve reaches over `days`, as `%{date:, balance:}`.

  When the balance never crosses zero the bankruptcy date is `nil` and the
  screen has nothing to point at, yet the horizon still has a worst day. That
  day is what a projection ending comfortably actually has to survive, so it is
  worth naming even — especially — when the news is good.

  Ties go to the earliest date: the first time the balance bottoms out is when
  the money has to be there.
  """
  def trough(projection, days \\ @default_horizon_days) do
    projection
    |> daily_balances(days)
    |> Enum.reduce(nil, fn point, lowest ->
      if is_nil(lowest) or Decimal.lt?(point.balance, lowest.balance),
        do: point,
        else: lowest
    end)
  end

  @doc """
  The change of the projected final balance against the current balance, as a
  signed whole percentage. `nil` when the starting balance is zero.
  """
  def projected_change_percent(%{starting_balance: starting_balance} = projection) do
    if Decimal.equal?(starting_balance, 0) do
      nil
    else
      projection
      |> final_balance()
      |> Decimal.sub(starting_balance)
      |> Decimal.div(starting_balance)
      |> Decimal.mult(100)
      |> Decimal.round(0)
    end
  end

  @doc """
  Categories eligible for a hand-created recurring item: the ones that do not
  have an item yet, minus the credit-card categories (card bills already enter
  the projection through `card_occurrences/2`, so registering one would count
  the same money twice). Ordered by name.
  """
  def list_categories_without_recurring_item do
    taken = MapSet.new(list_recurring_items(), & &1.category_id)

    Categories.list_categories()
    |> Enum.reject(&(MapSet.member?(taken, &1.id) or credit_card_category?(&1)))
    |> Enum.sort_by(& &1.name)
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
        build_card_occurrence(account, s.due_date, statement_amount(s), :boleto, nil)

      %Statement{} ->
        nil

      nil ->
        case estimate_for_month(account, month) do
          nil ->
            nil

          amount ->
            groups = Installments.account_installment_groups(account.id, month)
            build_card_occurrence(account, date, amount, :estimado, {month, groups})
        end
    end
  end

  defp statement_for_month(account_id, month) do
    month_end = Date.end_of_month(month)

    from(s in Statement,
      where: s.account_id == ^account_id and s.due_date >= ^month and s.due_date <= ^month_end,
      order_by: [desc: s.due_date, desc: s.inserted_at],
      limit: 1
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

  # The estimate is the average of this card's recent bills, not its last one.
  # A single bill is a sample of one: the Ourocard's last four came in at
  # 14.391,19 / 11.938,58 / 14.995,67 / 14.018,20, so whichever happened to be
  # most recent drove the whole year's projection, and a light month projected a
  # light year.
  #
  # What gets averaged is each bill's VARIABLE part -- the bill minus the
  # installments known for its own competência. Installments are not an average:
  # they are a schedule, so the target month's own installment total is added
  # back afterwards. Averaging the gross bill instead would smear a parcel that
  # ends in March across all twelve months.
  defp estimate_for_month(account, month) do
    since = Date.add(Date.utc_today(), -30 * @history_months)

    recent =
      from(s in Statement,
        where: s.account_id == ^account.id and not is_nil(s.due_date) and s.due_date >= ^since,
        order_by: [desc: s.due_date],
        limit: @estimate_sample
      )
      |> Repo.all()

    case recent do
      [] ->
        nil

      statements ->
        statements
        |> Enum.map(&variable_part/1)
        |> average()
        |> Decimal.sub(Installments.account_installment_total(account.id, month))
    end
  end

  defp variable_part(%Statement{} = statement) do
    competencia = statement.competencia || Date.beginning_of_month(statement.due_date)
    installments = Installments.account_installment_total(statement.account_id, competencia)

    statement |> statement_amount() |> Decimal.add(installments)
  end

  defp average(amounts) do
    amounts
    |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1))
    |> Decimal.div(length(amounts))
    |> Decimal.round(2)
  end

  defp build_card_occurrence(account, date, amount, origin, installments) do
    {total, groups} = installment_disclosure(installments)

    %{
      date: date,
      item: %{id: account.id, label: "Fatura #{account.name}", amount: amount, is_salary: false},
      balance_after: nil,
      origin: origin,
      installment_total: total,
      installment_groups: groups
    }
  end

  # A :boleto is a real imported statement: its amount is the statement's own
  # total and no installment breakdown is computed for it.
  defp installment_disclosure(nil), do: {Decimal.new("0"), []}

  defp installment_disclosure({month, groups}) do
    disclosed =
      Enum.map(groups, fn group ->
        %{
          id: group.id,
          description: group.description_pattern,
          parcel_value: Installments.parcel_value(group),
          parcel_number: Installments.parcel_position(group, month),
          installments: group.installments
        }
      end)

    total =
      Enum.reduce(disclosed, Decimal.new("0"), fn g, acc -> Decimal.add(acc, g.parcel_value) end)

    {total, disclosed}
  end

  @doc """
  Temporary recurrences: one occurrence per parcel, inside the horizon, for every
  commitment whose parcels are *not* already folded into a credit-card bill.

  Membership comes from `Installments.list_off_card_groups/0`, which decides by
  the account the parcels land on — the very fact that drives
  `Installments.account_installment_total/2` on the card-bill side. Because
  bill-inclusion is a strict subset of ruler-exclusion, a commitment can never be
  counted on both sides, whatever its `commitment_type` says.
  """
  def commitment_occurrences(today, horizon_end) do
    Installments.list_off_card_groups()
    |> Enum.flat_map(&group_occurrences(&1, today, horizon_end))
  end

  defp group_occurrences(
         %{start_date: %Date{} = start_date, installments: n} = group,
         today,
         horizon_end
       )
       when is_integer(n) and n >= 1 do
    amount = group |> Installments.parcel_value() |> Decimal.negate()
    ends_on = Installments.last_installment_date(group)

    0..(n - 1)
    |> Enum.map(&{&1 + 1, Installments.add_months(start_date, &1)})
    |> Enum.filter(fn {_position, date} ->
      Date.compare(date, today) != :lt and Date.compare(date, horizon_end) != :gt
    end)
    |> Enum.map(fn {position, date} ->
      %{
        date: date,
        item: %{
          id: group.id,
          label: group.description_pattern,
          amount: amount,
          is_salary: false
        },
        balance_after: nil,
        commitment: %{
          group_id: group.id,
          parcel_number: position,
          installments: n,
          ends_on: ends_on,
          commitment_type: Installments.commitment_type(group)
        }
      }
    end)
  end

  # coveralls-ignore-next-line — defensive: both fields are required by the changeset.
  defp group_occurrences(_group, _today, _horizon_end), do: []
end
