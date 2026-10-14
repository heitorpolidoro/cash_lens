defmodule CashLens.Installments do
  @moduledoc """
  The Installments context.
  """

  import Ecto.Query, warn: false

  alias CashLens.Ownership
  alias CashLens.Repo

  alias CashLens.Accounts.Account
  alias CashLens.CreditCards.Statement
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.InstallmentDetector
  alias CashLens.Transactions.Transaction
  alias CashLens.Users.User

  @doc """
  Returns the user's installment groups.
  """
  def list_installment_groups(%User{} = user) do
    from(g in Ownership.scope(InstallmentGroup, user), order_by: [desc: g.inserted_at])
    |> Repo.all()
    |> Enum.map(&load_dynamic_fields(user, &1))
  end

  @doc """
  Sum of installment parcels due in `month` for groups that touch
  `account_id` (i.e. at least one of the group's transactions belongs to
  that account). Positive magnitude, same convention as the internal
  month-total helper used by `upcoming_installments/1`.
  """
  def account_installment_total(%User{} = user, account_id, %Date{} = month) do
    user
    |> list_account_groups(account_id)
    |> total_due_in_month(month)
  end

  @doc """
  The installment groups behind `account_installment_total/2`: the groups that
  touch `account_id` and whose plan bills a parcel in `month`. The sum of their
  `parcel_value/1` is exactly what `account_installment_total/2` returns.
  """
  def account_installment_groups(%User{} = user, account_id, %Date{} = month) do
    user
    |> list_account_groups(account_id)
    |> groups_due_in_month(month)
  end

  @doc """
  Every installment group touching `account_id`, whatever the month. One query;
  the account scoping stays in it. Callers that need several months filter this
  result with `groups_due_in_month/2` / `total_due_in_month/2`.
  """
  def list_account_groups(%User{} = user, account_id) do
    transactions = Ownership.scope(Transaction, user)

    from(g in Ownership.scope(InstallmentGroup, user),
      join: t in ^transactions,
      on: t.installment_group_id == g.id,
      where: t.account_id == ^account_id,
      distinct: true,
      select: g
    )
    |> Repo.all()
  end

  @doc """
  The `groups` whose plan bills a parcel in `month`. Pure.
  """
  def groups_due_in_month(groups, %Date{} = month) do
    Enum.filter(groups, &parcel_due_in_month?(&1, month))
  end

  @doc """
  Sum of the parcels `groups` bill in `month`, as a positive magnitude. Pure.
  """
  def total_due_in_month(groups, %Date{} = month) do
    groups
    |> groups_due_in_month(month)
    |> Enum.reduce(Decimal.new("0"), fn g, acc -> Decimal.add(acc, parcel_value(g)) end)
  end

  @doc """
  The commitments whose parcels are *not* inside any credit-card bill: groups
  with no linked transaction on an account flagged `is_credit_card`.

  Membership is decided by where the money actually lands, not by
  `commitment_type`, because `account_installment_total/2` — the function that
  folds parcels into the credit-card bill estimate — selects groups by the
  account of their transactions. Using the same fact on both sides makes it
  impossible for a commitment to be counted twice. A group with no transaction
  at all is included: contributing to no account's total, it is in no bill.
  """
  def list_off_card_groups(%User{} = user) do
    accounts = Ownership.scope(Account, user)

    on_card =
      from(t in Ownership.scope(Transaction, user),
        join: a in ^accounts,
        on: a.id == t.account_id,
        where: parent_as(:group).id == t.installment_group_id and a.is_credit_card == true,
        select: 1
      )

    from(g in Ownership.scope(InstallmentGroup, user),
      as: :group,
      where: not exists(subquery(on_card)),
      order_by: [asc: g.start_date, asc: g.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single installment group.
  """
  def get_installment_group!(%User{} = user, id) do
    case fetch_group(user, id) do
      nil -> raise Ecto.NoResultsError, queryable: InstallmentGroup
      group -> load_dynamic_fields(user, group)
    end
  end

  defp fetch_group(user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> InstallmentGroup |> Ownership.scope(user) |> Repo.get(id)
      :error -> nil
    end
  end

  @doc """
  Creates an installment group owned by `user`; a `"user_id"` in `attrs` is ignored.
  """
  def create_installment_group(%User{} = user, attrs \\ %{}) do
    %InstallmentGroup{user_id: user.id}
    |> InstallmentGroup.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        link_matching_transactions(user, group)
        CashLens.Forecast.deactivate_superseded_items(user)
        {:ok, load_dynamic_fields(user, group)}

      error ->
        error
    end
  end

  @doc """
  Updates one of the user's installment groups; `{:error, :not_found}` for anyone else's.
  """
  def update_installment_group(%User{} = user, %InstallmentGroup{id: id}, attrs) do
    case fetch_group(user, id) do
      nil ->
        {:error, :not_found}

      group ->
        group
        |> InstallmentGroup.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated_group} ->
            link_matching_transactions(user, updated_group)
            CashLens.Forecast.deactivate_superseded_items(user)
            {:ok, load_dynamic_fields(user, updated_group)}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes one of the user's installment groups; `{:error, :not_found}` for anyone else's.
  """
  def delete_installment_group(%User{} = user, %InstallmentGroup{id: id}) do
    case fetch_group(user, id) do
      nil -> {:error, :not_found}
      group -> do_delete_group(user, group)
    end
  end

  defp do_delete_group(user, group) do
    # The parcels outlive the grouping: deleting a commitment undoes how its
    # transactions were read together, never the transactions themselves. The
    # foreign key is NO ACTION, so they have to be unlinked first or Postgres
    # refuses the delete outright.
    Repo.transaction(fn ->
      from(t in Ownership.scope(Transaction, user), where: t.installment_group_id == ^group.id)
      |> Repo.update_all(set: [installment_group_id: nil, installment_number: nil])

      Repo.delete!(group)
    end)
  end

  @doc """
  Returns a group with its calculated progress.
  """
  def get_group_with_progress(%User{} = user, group_id) do
    group = get_installment_group!(user, group_id)

    paid_count =
      Repo.aggregate(
        from(t in Ownership.scope(Transaction, user), where: t.installment_group_id == ^group.id),
        :count
      )

    Map.merge(group, %{
      paid_count: paid_count,
      remaining_count: max(0, group.installments - paid_count),
      is_completed: paid_count >= group.installments,
      is_finished: finished?(group)
    })
  end

  # A plan is "finished" once its last parcel's billing month is already in the past.
  # start_date holds the original purchase date; the final parcel bills
  # (installments - 1) months later.
  # coveralls-ignore-next-line — defensive: start_date is required, so nil never occurs in practice.
  defp finished?(%{start_date: nil}), do: false

  defp finished?(%{start_date: start_date, installments: installments}) do
    last_billing = add_months(start_date, installments - 1)
    today = Date.utc_today()
    current_month_start = Date.new!(today.year, today.month, 1)
    Date.compare(last_billing, current_month_start) == :lt
  end

  @doc """
  Returns the date of the final installment for a group:
  start_date shifted forward by (installments - 1) months. Nil if no start_date.
  """
  def last_installment_date(%{start_date: %Date{} = start_date, installments: n})
      when is_integer(n) and n >= 1 do
    add_months(start_date, n - 1)
  end

  def last_installment_date(_), do: nil

  @doc """
  Lists the transactions (parcels) linked to an installment group,
  ordered by installment number, then by date.
  """
  def list_group_transactions(%User{} = user, group_id) do
    from(t in Ownership.scope(Transaction, user),
      where: t.installment_group_id == ^group_id,
      order_by: [asc_nulls_last: t.installment_number, asc: t.date]
    )
    |> Repo.all()
  end

  # Adds n calendar months to a date, clamping the day to the target month's length.
  def add_months(date, 0), do: date

  def add_months(%Date{year: y, month: m, day: d}, n) do
    total = y * 12 + (m - 1) + n
    ny = div(total, 12)
    nm = rem(total, 12) + 1
    last_day = Date.days_in_month(Date.new!(ny, nm, 1))
    Date.new!(ny, nm, min(d, last_day))
  end

  @doc """
  Projects the installment burden per month.

  Starts at the first month whose installment data isn't fully imported yet (so a
  past month still missing its statement shows up flagged as pending) and goes
  forward up to `max_months` from the current month. Each entry is
  `%{date: Date.t(), total: Decimal.t(), pending: boolean()}`, where `pending` marks
  a month that already passed but whose statement hasn't been imported.
  """
  def upcoming_installments(%User{} = user, max_months \\ 12) do
    today = Date.utc_today()
    current = Date.new!(today.year, today.month, 1)
    groups = list_installment_groups(user)

    start_month = min_date(first_incomplete_month(user), current)
    last_month = add_months(current, max_months - 1)
    count = month_diff(start_month, last_month)

    0..count
    |> Enum.map(fn i ->
      month = add_months(start_month, i)
      total = month_installment_total(groups, month)
      %{date: month, total: total, pending: Date.compare(month, current) == :lt}
    end)
    # Drop trailing future months with nothing due (keep pending past months).
    |> Enum.reverse()
    |> Enum.drop_while(&(not &1.pending and Decimal.eq?(&1.total, 0)))
    |> Enum.reverse()
  end

  # Sum of the parcels due in a given month across all installment groups.
  defp month_installment_total(groups, month) do
    groups
    |> Enum.filter(&parcel_due_in_month?(&1, month))
    |> Enum.reduce(Decimal.new("0"), fn g, acc -> Decimal.add(acc, parcel_value(g)) end)
  end

  # First month whose installment data isn't fully imported (based on the latest
  # imported installment transaction).
  defp first_incomplete_month(user) do
    case Repo.one(
           from t in Ownership.scope(Transaction, user),
             where: not is_nil(t.installment_group_id),
             select: max(t.date)
         ) do
      nil ->
        today = Date.utc_today()
        Date.new!(today.year, today.month, 1)

      frontier ->
        fm = Date.new!(frontier.year, frontier.month, 1)

        if Date.compare(frontier, Date.end_of_month(frontier)) == :eq,
          do: add_months(fm, 1),
          else: fm
    end
  end

  defp min_date(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)

  defp month_diff(from, to), do: to.year * 12 + to.month - (from.year * 12 + from.month)

  @doc """
  The monthly parcel of a commitment: the total divided by the parcel count,
  rounded to two decimal places. The rounding is part of the contract — callers
  must not re-derive the raw quotient, or the same plan would show one figure on
  the forecast ruler and another inside the credit-card bill disclosure.
  """
  def parcel_value(%{total_amount: nil}), do: Decimal.new("0")

  def parcel_value(%{total_amount: total, installments: n}) when n > 0 do
    Decimal.div(total, n) |> Decimal.round(2)
  end

  # coveralls-ignore-next-line — defensive fallthrough; installments is validated > 1.
  def parcel_value(_), do: Decimal.new("0")

  @doc """
  The 1-based position of the parcel billing in `month`, or `nil` when `month`
  falls outside the plan's window.
  """
  def parcel_position(%{start_date: %Date{} = start_date, installments: n}, %Date{} = month)
      when is_integer(n) do
    position = month_diff(month_start(start_date), month) + 1
    if position >= 1 and position <= n, do: position, else: nil
  end

  # coveralls-ignore-next-line — defensive: start_date is required, so nil never occurs in practice.
  def parcel_position(_group, _month), do: nil

  # coveralls-ignore-next-line — defensive: start_date is required, so nil never occurs in practice.
  defp parcel_due_in_month?(%{start_date: nil}, _month), do: false

  defp parcel_due_in_month?(%{start_date: start_date, installments: n}, month) do
    start_month = Date.new!(start_date.year, start_date.month, 1)
    last_month = add_months(start_month, n - 1)
    Date.compare(month, start_month) != :lt and Date.compare(month, last_month) != :gt
  end

  @doc """
  Returns all active (non-completed) installment groups.
  """
  def list_active_groups(%User{} = user) do
    groups = list_installment_groups(user)

    # Simple in-memory filtering for now; can be optimized with SQL if needed.
    Enum.filter(groups, fn g ->
      progress = get_group_with_progress(user, g.id)
      !progress.is_completed
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking installment group changes.
  """
  def change_installment_group(%InstallmentGroup{} = group, attrs \\ %{}) do
    InstallmentGroup.changeset(group, attrs)
  end

  @doc """
  Finds a matching installment group for a given description.
  """
  def find_matching_group(%User{}, nil), do: nil

  def find_matching_group(%User{} = user, description) when is_binary(description) do
    desc = String.downcase(description)

    # We look for groups whose description_pattern is contained in the transaction description.
    # Case-insensitive.
    Repo.one(
      from g in Ownership.scope(InstallmentGroup, user),
        where: fragment("? ILIKE '%' || ? || '%'", ^desc, g.description_pattern),
        limit: 1
    )
    |> then(&load_dynamic_fields(user, &1))
  end

  @doc """
  Scans every transaction whose description still contains an installment marker
  ("PARC X/Y") and groups them. Returns the number of transactions linked.

  Used both for one-off backfills and for the "detect installments" UI action.
  """
  def scan_and_apply_all(%User{} = user) do
    Transaction
    |> Ownership.scope(user)
    |> where([t], like(t.description, "%PARC %"))
    |> where([t], is_nil(t.installment_group_id))
    |> Repo.all()
    |> then(&detect_and_apply(user, &1))
  end

  @doc """
  Detects installment markers in the given transactions, creating/reusing one
  `InstallmentGroup` per (merchant base, total installments) and linking each
  transaction to it.

  The transaction description is cleaned to the merchant base, while the original
  `fingerprint` is preserved (we use `update_all`, bypassing the changeset) so that
  re-importing the same statement still de-duplicates correctly.

  Returns the number of transactions linked.
  """
  def detect_and_apply(%User{} = user, transactions) when is_list(transactions) do
    detected =
      user
      |> owned_only(transactions)
      |> Enum.map(fn tx -> {tx, InstallmentDetector.detect(tx.description)} end)
      |> Enum.reject(fn {_tx, detection} -> is_nil(detection) end)

    count =
      detected
      # Group by merchant + total + rounded value: parcels of one purchase differ by
      # at most a few cents (the first carries the rounding remainder), while distinct
      # purchases at the same merchant differ by reais — so round to the nearest real.
      |> Enum.group_by(fn {tx, d} -> {d.base, d.total, amount_key(tx.amount)} end)
      |> Enum.reduce(0, fn {key, items}, acc ->
        acc + apply_installment_group(user, key, items)
      end)

    # Re-dating parcels moves them across months, so rebuild the affected accounts'
    # balance chains to keep monthly summaries correct.
    detected
    |> Enum.map(fn {tx, _d} -> tx.account_id end)
    |> Enum.uniq()
    |> Enum.each(&CashLens.Accounting.rebuild_account_balances(user, &1))

    count
  end

  # Only transactions the user owns are ever read from or written to.
  defp owned_only(_user, []), do: []

  defp owned_only(user, transactions) do
    ids = Enum.map(transactions, & &1.id)

    owned =
      from(t in Ownership.scope(Transaction, user), where: t.id in ^ids, select: t.id)
      |> Repo.all()
      |> MapSet.new()

    Enum.filter(transactions, &MapSet.member?(owned, &1.id))
  end

  # Spreads one purchase's parcels to their billing months, drops not-yet-charged
  # future parcels, links the rest to a group, and returns how many were applied.
  defp apply_installment_group(user, {base, total, amount_key}, items) do
    # "PARC xx/yy" denotes one installment purchase whose parcels are each
    # reported on the ORIGINAL purchase date, so every parcel of a plan carries
    # the same date and must be re-dated to the month it is actually billed.
    today = Date.utc_today()
    competencias = competencias_for(user, items)
    closing_days = closing_days_for(user, items)

    dated =
      Enum.map(items, fn {tx, d} ->
        {tx, d, billing_date(tx, d, competencias, closing_days)}
      end)

    # A parcel billed in a future month has not actually been charged yet, so it
    # is not a real transaction — drop it from the database.
    {future, present} =
      Enum.split_with(dated, fn {_tx, _d, billed} -> Date.compare(billed, today) == :gt end)

    Enum.each(future, fn {tx, _d, _billed} ->
      from(t in Ownership.scope(Transaction, user), where: t.id == ^tx.id) |> Repo.delete_all()
    end)

    apply_present_parcels(user, base, total, amount_key, present)
  end

  # The month a parcel is billed in. Preferred source: the statement the row was
  # imported from. A card statement physically lists each parcel in the cycle
  # that charges it, so the competência IS the billing month -- no inference
  # needed, and it survives the two things inference cannot handle: a card whose
  # cycle changed (this account's due day moved from 7 to 16 in May 2026, so
  # today's closing_day is wrong for every older purchase) and a plan whose
  # parcels skip a month, which real statements do.
  #
  # Fallback, for a row with no statement behind it (a hand-entered parcel, or
  # one imported from an account-level extract): infer the cycle from the card's
  # closing_day -- a purchase after closing belongs to the next month's bill --
  # and advance (number - 1) months from there.
  defp billing_date(tx, detection, competencias, closing_days) do
    case Map.get(competencias, tx.import_batch_id) do
      %Date{} = competencia -> on_day(competencia, tx.date.day)
      nil -> inferred_billing_date(tx, detection, Map.get(closing_days, tx.account_id))
    end
  end

  defp inferred_billing_date(tx, detection, closing_day) do
    first =
      if is_integer(closing_day) and tx.date.day > closing_day,
        do: add_months(tx.date, 1),
        else: tx.date

    add_months(first, detection.number - 1)
  end

  defp on_day(%Date{year: year, month: month}, day) do
    last_day = Date.days_in_month(Date.new!(year, month, 1))
    Date.new!(year, month, min(day, last_day))
  end

  defp competencias_for(user, items) do
    ids =
      items
      |> Enum.map(fn {tx, _d} -> tx.import_batch_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(s in Ownership.scope(Statement, user),
        where: s.id in ^ids and not is_nil(s.competencia),
        select: {s.id, s.competencia}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp closing_days_for(user, items) do
    ids = items |> Enum.map(fn {tx, _d} -> tx.account_id end) |> Enum.uniq()

    from(a in Ownership.scope(Account, user), where: a.id in ^ids, select: {a.id, a.closing_day})
    |> Repo.all()
    |> Map.new()
  end

  defp apply_present_parcels(_user, _base, _total, _amount_key, []), do: 0

  defp apply_present_parcels(user, base, total, amount_key, present) do
    group = find_or_create_group(user, base, total, amount_key, present)

    Enum.each(present, fn {tx, d, billed} -> link_and_clean(user, tx, group, d, billed) end)

    account_id = present |> hd() |> elem(0) |> Map.get(:account_id)
    fill_group_categories(user, group, base, account_id)

    length(present)
  end

  # Fills the category of the group's parcels that have none. Inherits the most
  # common category among already-categorized parcels; if none exist, falls back to
  # AutoCategorizer over the cleaned merchant-base description. Never overwrites an
  # existing category and never touches the fingerprint.
  defp fill_group_categories(user, group, base, account_id) do
    txs =
      Repo.all(
        from t in Ownership.scope(Transaction, user),
          where: t.installment_group_id == ^group.id,
          select: %{id: t.id, category_id: t.category_id}
      )

    case group_category_id(user, txs, base, account_id) do
      nil ->
        :ok

      category_id ->
        from(t in Ownership.scope(Transaction, user),
          where: t.installment_group_id == ^group.id and is_nil(t.category_id)
        )
        |> Repo.update_all(set: [category_id: category_id])

        :ok
    end
  end

  defp group_category_id(user, txs, base, account_id) do
    existing = txs |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1)

    case existing do
      [] ->
        %{description: base, account_id: account_id}
        |> then(&AutoCategorizer.categorize(user, &1))
        |> Map.get(:category_id)

      ids ->
        ids
        |> Enum.frequencies()
        |> Enum.max_by(fn {_id, count} -> count end)
        |> elem(0)
    end
  end

  # Rounds the absolute amount to the nearest whole real, as an integer.
  defp amount_key(amount) do
    amount |> Decimal.abs() |> Decimal.round(0) |> Decimal.to_integer()
  end

  # Where the plan starts: the month parcel 1 is billed in, which drives
  # `parcel_due_in_month?/2` and therefore the whole forecast of this plan.
  #
  # Derived from the lowest-numbered parcel present, back-shifted to parcel 1,
  # rather than from a purchase date -- the purchase month is not the billing
  # month whenever the purchase falls after the cycle closes. The lowest number
  # is used because it is the closest anchor to parcel 1 and so accumulates the
  # least drift when a statement skips a parcel.
  defp plan_start_date(items) do
    {_tx, detection, billed} = Enum.min_by(items, fn {_tx, d, _billed} -> d.number end)

    add_months(billed, -(detection.number - 1))
  end

  defp find_or_create_group(user, base, total, amount_key, items) do
    pattern = "#{base} (#{total}x · R$#{amount_key})"

    case InstallmentGroup |> Ownership.scope(user) |> Repo.get_by(description_pattern: pattern) do
      nil ->
        {tx, _d, _billed} = hd(items)
        start_date = plan_start_date(items)
        total_amount = tx.amount |> Decimal.abs() |> Decimal.mult(total)

        {:ok, group} =
          create_installment_group(user, %{
            description_pattern: pattern,
            installments: total,
            start_date: start_date,
            total_amount: total_amount
          })

        group

      group ->
        group
    end
  end

  # Links a parcel to its group, cleans the description to the merchant base, and sets
  # its billing date (computed by the caller).
  #
  # The update is done via `update_all` (not the changeset) so the original
  # `dedup_key`/`fingerprint` — derived from the raw date and the raw
  # "PARC xx/yy" description — are preserved. Re-importing the same statement
  # recomputes those raw values and still de-duplicates. The "PARC xx/yy" marker
  # in the raw memo also self-disambiguates parcels, so each installment lands on
  # its own dedup_key (occurrence index 0) without relying on the ordinal.
  defp link_and_clean(user, tx, group, detection, billed_date) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Ownership.scope(Transaction, user), where: t.id == ^tx.id)
    |> Repo.update_all(
      set: [
        description: detection.base,
        date: billed_date,
        installment_group_id: group.id,
        installment_number: detection.number,
        updated_at: now
      ]
    )
  end

  @doc """
  Automatically associates unlinked transactions that match the group's description pattern and start date.
  If the group is edited, it first unlinks any existing associated transactions before re-associating.
  Auto-detected groups are ignored since their parcels are explicitly linked by the scan process.
  """
  def associate_matching_transactions(%User{} = user, %InstallmentGroup{id: id}) do
    case fetch_group(user, id) do
      nil -> {:error, :not_found}
      group -> link_matching_transactions(user, group)
    end
  end

  defp link_matching_transactions(user, %InstallmentGroup{} = group) do
    if Regex.match?(~r/\(\d+x · R\$\d+\)$/, group.description_pattern) do
      # Auto-detected groups are handled by detect_and_apply/1, do not auto-associate
      :ok
    else
      # Manual groups: unlink existing and re-associate by pattern
      from(t in Ownership.scope(Transaction, user), where: t.installment_group_id == ^group.id)
      |> Repo.update_all(set: [installment_group_id: nil, installment_number: nil])

      pattern = "%#{group.description_pattern}%"

      unlinked_matches =
        Repo.all(
          from t in Ownership.scope(Transaction, user),
            where:
              is_nil(t.installment_group_id) and ilike(t.description, ^pattern) and
                t.date >= ^group.start_date,
            order_by: [asc: t.date],
            limit: ^group.installments
        )

      Enum.each(unlinked_matches, fn tx ->
        from(t in Ownership.scope(Transaction, user), where: t.id == ^tx.id)
        |> Repo.update_all(
          set: [
            installment_group_id: group.id,
            installment_number: parcel_number_on(group, tx.date),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )
      end)

      :ok
    end
  end

  # Which parcel of `group` a debit dated `date` is, counted in months from the
  # plan's first parcel rather than by position in the matched list. A contract
  # that began before the imported statement has its early parcels missing, and
  # numbering what did arrive 1, 2, 3… would label a 2025 debit as parcel 1 of a
  # plan that started in 2020.
  defp parcel_number_on(%{start_date: start_date, installments: n}, %Date{} = date) do
    start_date
    |> month_start()
    |> month_diff(month_start(date))
    |> Kernel.+(1)
    |> max(1)
    |> min(n)
  end

  @doc """
  Dynamically calculates total_amount and installment_amount at read-time if total_amount is nil.
  """
  def load_dynamic_fields(%User{}, nil), do: nil

  def load_dynamic_fields(%User{} = user, %InstallmentGroup{} = group) do
    cond do
      not is_nil(group.total_amount) ->
        inst_val = Decimal.round(Decimal.div(group.total_amount, group.installments), 2)
        %{group | installment_amount: inst_val}

      not is_nil(group.description_pattern) ->
        pattern = "%#{group.description_pattern}%"

        query =
          from t in Ownership.scope(Transaction, user),
            where: ilike(t.description, ^pattern),
            order_by: [desc: t.date, desc: t.inserted_at],
            limit: 1

        case Repo.one(query) do
          nil ->
            group

          transaction ->
            valor_parcela = Decimal.abs(transaction.amount)
            calculated_total = Decimal.mult(valor_parcela, group.installments)

            %{group | installment_amount: valor_parcela, total_amount: calculated_total}
        end

      true ->
        group
    end
  end

  @relief_window_months 1
  @suggestion_min_occurrences 3

  @doc """
  The supported commitment modalities, in display order.
  """
  def commitment_types, do: InstallmentGroup.commitment_types()

  @doc """
  First day of the month currently in course (UTC).
  """
  def current_month do
    today = Date.utc_today()
    Date.new!(today.year, today.month, 1)
  end

  @doc """
  What the user owes in `month`, broken down by commitment type.

  Returns `%{total: Decimal.t(), by_type: %{type => %{amount: Decimal.t(), count: non_neg_integer}}}`
  where `count` is how many commitments of that type have a parcel due in the
  month. The breakdown always sums back to `:total`.
  """
  def monthly_commitment(%User{} = user, month \\ current_month()) do
    groups = list_installment_groups(user)

    by_type =
      Map.new(commitment_types(), fn type ->
        due = groups_of_type_due_in(groups, type, month)
        {type, %{amount: sum_parcels(due), count: length(due)}}
      end)

    total =
      by_type
      |> Map.values()
      |> Enum.reduce(Decimal.new("0"), fn %{amount: amount}, acc -> Decimal.add(acc, amount) end)

    %{total: total, by_type: by_type}
  end

  @doc """
  Consolidated outstanding debt as of `month`, broken down by commitment type.

  A commitment's remaining debt is its parcel value times the number of parcels
  still to be billed, counting `month` itself as still due. Summing
  `monthly_projection/2` from `month` to the end of every plan therefore yields
  exactly this total.
  """
  def outstanding_balance(%User{} = user, month \\ current_month()) do
    groups = list_installment_groups(user)

    by_type =
      Map.new(commitment_types(), fn type ->
        amount =
          groups
          |> Enum.filter(&(commitment_type(&1) == type))
          |> Enum.reduce(Decimal.new("0"), fn g, acc ->
            Decimal.add(acc, remaining_debt(g, month))
          end)

        {type, amount}
      end)

    total =
      by_type
      |> Map.values()
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1))

    %{total: total, by_type: by_type}
  end

  @doc """
  How much monthly commitment frees up over the next `window` months (the
  reference month alone, by default), because the plans listed bill their last
  parcel inside that window. With the default window the figure answers "how
  much lighter is next month", since a plan whose last parcel falls in `month`
  stops costing anything from the month after.

  Returns `%{total: Decimal.t(), items: [...]}` ordered by the month the plan
  ends. Commitments *starting* inside the window are not netted out: this metric
  answers "how much breathing room is coming", not "what the net balance will be".
  """
  def cash_flow_relief(%User{} = user, month \\ current_month(), window \\ @relief_window_months) do
    last_month = add_months(month, window - 1)

    items =
      user
      |> list_installment_groups()
      |> Enum.filter(&ends_between?(&1, month, last_month))
      |> Enum.map(fn g ->
        %{
          date: month_start(last_installment_date(g)),
          description: g.description_pattern,
          commitment_type: commitment_type(g),
          amount: parcel_value(g)
        }
      end)
      |> Enum.sort_by(& &1.date, Date)

    total = Enum.reduce(items, Decimal.new("0"), fn i, acc -> Decimal.add(acc, i.amount) end)

    %{total: total, items: items}
  end

  @doc """
  Projects the monthly commitment for `months` months starting at `month`,
  split by commitment type so the UI can stack one proportional bar per month.

  Each entry is `%{date:, total:, credit_card:, financing:, consorcio:, emprestimo:,
  current?:}`
  and the three type amounts always add up to `:total`.
  """
  def monthly_projection(%User{} = user, month \\ current_month(), months \\ 10) do
    groups = list_installment_groups(user)
    current = current_month()

    Enum.map(0..(months - 1), fn offset ->
      projected_month(groups, add_months(month, offset), current)
    end)
  end

  defp projected_month(groups, month, current) do
    by_type =
      Map.new(commitment_types(), fn type ->
        {type, groups |> groups_of_type_due_in(type, month) |> sum_parcels()}
      end)

    total =
      by_type
      |> Map.values()
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1))

    %{
      date: month,
      total: total,
      credit_card: by_type["credit_card"],
      financing: by_type["financing"],
      consorcio: by_type["consorcio"],
      emprestimo: by_type["emprestimo"],
      current?: Date.compare(month, current) == :eq
    }
  end

  @doc """
  Recurring debits in the statement that are not linked to any commitment yet,
  used by the "new commitment" modal to auto-fill the form.

  Only descriptions seen at least #{@suggestion_min_occurrences} times are
  returned, most frequent first. `query` narrows them by substring, which is
  what makes a long statement searchable instead of a 20-row dropdown.

  `amount` is the value of the *latest* occurrence, not the average, so that a
  parcel that drifts month to month — a mortgage whose insurance premium shrinks
  with the balance — suggests what the next one will actually cost. That is also
  the value `load_dynamic_fields/1` reads back once the group exists, so the form
  and the screen agree.
  """
  def suggest_commitment_patterns(%User{} = user, query \\ "", limit \\ 20) do
    rows =
      from(t in Ownership.scope(Transaction, user),
        where: is_nil(t.installment_group_id) and t.amount < 0,
        group_by: t.description,
        having: count(t.id) >= @suggestion_min_occurrences,
        order_by: [desc: count(t.id), asc: t.description],
        limit: ^limit,
        select: %{
          description: t.description,
          occurrences: count(t.id),
          first_date: min(t.date),
          last_date: max(t.date)
        }
      )
      |> filter_by_description(query)
      |> Repo.all()

    latest = latest_amounts(user, Enum.map(rows, & &1.description))

    Enum.map(rows, &Map.put(&1, :amount, Map.get(latest, &1.description, Decimal.new("0"))))
  end

  defp filter_by_description(queryable, blank) when blank in [nil, ""], do: queryable

  defp filter_by_description(queryable, query) do
    where(queryable, [t], ilike(t.description, ^"%#{query}%"))
  end

  # The newest debit per description. Ordered exactly like `load_dynamic_fields/1`
  # so both answer "the last parcel" with the same row when two share a date.
  defp latest_amounts(_user, []), do: %{}

  defp latest_amounts(user, descriptions) do
    from(t in Ownership.scope(Transaction, user),
      where: t.description in ^descriptions and t.amount < 0,
      distinct: t.description,
      order_by: [asc: t.description, desc: t.date, desc: t.inserted_at],
      select: {t.description, t.amount}
    )
    |> Repo.all()
    |> Map.new(fn {description, amount} -> {description, Decimal.abs(amount)} end)
  end

  @doc """
  The commitment type of a group, defaulting to `"credit_card"` for rows that
  predate the commitment-type column.
  """
  def commitment_type(%{commitment_type: type}) when is_binary(type), do: type
  def commitment_type(_group), do: "credit_card"

  @doc """
  Remaining debt of a single commitment as of `month` (inclusive).
  """
  def remaining_debt(group, month \\ current_month()) do
    Decimal.mult(parcel_value(group), remaining_parcels(group, month))
  end

  @doc """
  How many parcels of `group` are still to be billed from `month` on (inclusive).
  """
  def remaining_parcels(group, month \\ current_month())

  # coveralls-ignore-next-line — defensive: start_date is required, so nil never occurs in practice.
  def remaining_parcels(%{start_date: nil}, _month), do: 0

  def remaining_parcels(%{start_date: start_date, installments: n}, month) do
    elapsed = month_diff(month_start(start_date), month)
    n |> Kernel.-(elapsed) |> min(n) |> max(0)
  end

  defp groups_of_type_due_in(groups, type, month) do
    Enum.filter(groups, &(commitment_type(&1) == type and parcel_due_in_month?(&1, month)))
  end

  defp sum_parcels(groups) do
    Enum.reduce(groups, Decimal.new("0"), fn g, acc -> Decimal.add(acc, parcel_value(g)) end)
  end

  defp ends_between?(group, from_month, to_month) do
    case last_installment_date(group) do
      %Date{} = date ->
        month = month_start(date)
        Date.compare(month, from_month) != :lt and Date.compare(month, to_month) != :gt

      # coveralls-ignore-next-line — defensive: start_date is required, so nil never occurs in practice.
      _ ->
        false
    end
  end

  defp month_start(%Date{year: y, month: m}), do: Date.new!(y, m, 1)
end
