defmodule CashLens.Installments do
  @moduledoc """
  The Installments context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.InstallmentDetector
  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of installment groups.
  """
  def list_installment_groups do
    from(g in InstallmentGroup, order_by: [desc: g.inserted_at])
    |> Repo.all()
    |> Enum.map(&load_dynamic_fields/1)
  end

  @doc """
  Gets a single installment group.
  """
  def get_installment_group!(id) do
    Repo.get!(InstallmentGroup, id)
    |> load_dynamic_fields()
  end

  @doc """
  Creates an installment group.
  """
  def create_installment_group(attrs \\ %{}) do
    %InstallmentGroup{}
    |> InstallmentGroup.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        associate_matching_transactions(group)
        {:ok, load_dynamic_fields(group)}

      error ->
        error
    end
  end

  @doc """
  Updates an installment group.
  """
  def update_installment_group(%InstallmentGroup{} = group, attrs) do
    group
    |> InstallmentGroup.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        associate_matching_transactions(updated_group)
        {:ok, load_dynamic_fields(updated_group)}

      error ->
        error
    end
  end

  @doc """
  Deletes an installment group.
  """
  def delete_installment_group(%InstallmentGroup{} = group) do
    Repo.delete(group)
  end

  @doc """
  Returns a group with its calculated progress.
  """
  def get_group_with_progress(group_id) do
    group = get_installment_group!(group_id)

    paid_count =
      Repo.aggregate(
        from(t in Transaction, where: t.installment_group_id == ^group.id),
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
  def list_group_transactions(group_id) do
    from(t in Transaction,
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
  def upcoming_installments(max_months \\ 12) do
    today = Date.utc_today()
    current = Date.new!(today.year, today.month, 1)
    groups = list_installment_groups()

    start_month = min_date(first_incomplete_month(), current)
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
  defp first_incomplete_month do
    case Repo.one(
           from t in Transaction, where: not is_nil(t.installment_group_id), select: max(t.date)
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

  defp parcel_value(%{total_amount: nil}), do: Decimal.new("0")

  defp parcel_value(%{total_amount: total, installments: n}) when n > 0 do
    Decimal.div(total, n) |> Decimal.round(2)
  end

  # coveralls-ignore-next-line — defensive fallthrough; installments is validated > 1.
  defp parcel_value(_), do: Decimal.new("0")

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
  def list_active_groups do
    groups = list_installment_groups()

    # Simple in-memory filtering for now; can be optimized with SQL if needed.
    Enum.filter(groups, fn g ->
      progress = get_group_with_progress(g.id)
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
  def find_matching_group(nil), do: nil

  def find_matching_group(description) when is_binary(description) do
    desc = String.downcase(description)

    # We look for groups whose description_pattern is contained in the transaction description.
    # Case-insensitive.
    Repo.one(
      from g in InstallmentGroup,
        where: fragment("? ILIKE '%' || ? || '%'", ^desc, g.description_pattern),
        limit: 1
    )
    |> load_dynamic_fields()
  end

  @doc """
  Scans every transaction whose description still contains an installment marker
  ("PARC X/Y") and groups them. Returns the number of transactions linked.

  Used both for one-off backfills and for the "detect installments" UI action.
  """
  def scan_and_apply_all do
    Transaction
    |> where([t], like(t.description, "%PARC %"))
    |> where([t], is_nil(t.installment_group_id))
    |> Repo.all()
    |> detect_and_apply()
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
  def detect_and_apply(transactions) when is_list(transactions) do
    detected =
      transactions
      |> Enum.map(fn tx -> {tx, InstallmentDetector.detect(tx.description)} end)
      |> Enum.reject(fn {_tx, detection} -> is_nil(detection) end)

    count =
      detected
      # Group by merchant + total + rounded value: parcels of one purchase differ by
      # at most a few cents (the first carries the rounding remainder), while distinct
      # purchases at the same merchant differ by reais — so round to the nearest real.
      |> Enum.group_by(fn {tx, d} -> {d.base, d.total, amount_key(tx.amount)} end)
      |> Enum.reduce(0, fn {key, items}, acc -> acc + apply_installment_group(key, items) end)

    # Re-dating parcels moves them across months, so rebuild the affected accounts'
    # balance chains to keep monthly summaries correct.
    detected
    |> Enum.map(fn {tx, _d} -> tx.account_id end)
    |> Enum.uniq()
    |> Enum.each(&CashLens.Accounting.rebuild_account_balances/1)

    count
  end

  # Spreads one purchase's parcels to their billing months, drops not-yet-charged
  # future parcels, links the rest to a group, and returns how many were applied.
  defp apply_installment_group({base, total, amount_key}, items) do
    # "PARC xx/yy" always denotes a single installment purchase whose parcels are
    # each reported on their own purchase date (OFX DTPOSTED). Re-date every parcel
    # to its billing month: add_months(its own DTPOSTED, number - 1), so parcel 1
    # bills in the purchase month and parcel N bills (N - 1) months later.
    today = Date.utc_today()

    dated =
      Enum.map(items, fn {tx, d} ->
        billed = add_months(tx.date, d.number - 1)
        {tx, d, billed}
      end)

    # A parcel billed in a future month has not actually been charged yet, so it
    # is not a real transaction — drop it from the database.
    {future, present} =
      Enum.split_with(dated, fn {_tx, _d, billed} -> Date.compare(billed, today) == :gt end)

    Enum.each(future, fn {tx, _d, _billed} -> Repo.delete(tx) end)

    apply_present_parcels(base, total, amount_key, present)
  end

  defp apply_present_parcels(_base, _total, _amount_key, []), do: 0

  defp apply_present_parcels(base, total, amount_key, present) do
    group =
      find_or_create_group(
        base,
        total,
        amount_key,
        Enum.map(present, fn {tx, d, _} -> {tx, d} end)
      )

    Enum.each(present, fn {tx, d, billed} -> link_and_clean(tx, group, d, billed) end)

    account_id = present |> hd() |> elem(0) |> Map.get(:account_id)
    fill_group_categories(group, base, account_id)

    length(present)
  end

  # Fills the category of the group's parcels that have none. Inherits the most
  # common category among already-categorized parcels; if none exist, falls back to
  # AutoCategorizer over the cleaned merchant-base description. Never overwrites an
  # existing category and never touches the fingerprint.
  defp fill_group_categories(group, base, account_id) do
    txs =
      Repo.all(
        from t in Transaction,
          where: t.installment_group_id == ^group.id,
          select: %{id: t.id, category_id: t.category_id}
      )

    case group_category_id(txs, base, account_id) do
      nil ->
        :ok

      category_id ->
        from(t in Transaction,
          where: t.installment_group_id == ^group.id and is_nil(t.category_id)
        )
        |> Repo.update_all(set: [category_id: category_id])

        :ok
    end
  end

  defp group_category_id(txs, base, account_id) do
    existing = txs |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1)

    case existing do
      [] ->
        %{description: base, account_id: account_id}
        |> AutoCategorizer.categorize()
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

  defp find_or_create_group(base, total, amount_key, items) do
    pattern = "#{base} (#{total}x · R$#{amount_key})"

    case Repo.get_by(InstallmentGroup, description_pattern: pattern) do
      nil ->
        {tx, _d} = hd(items)
        # Each parcel's DTPOSTED is the original purchase date, so the plan's start
        # (purchase month, where parcel 1 bills) is the earliest DTPOSTED seen — the
        # basis for projecting the plan's end via add_months(start, installments - 1).
        start_date = items |> Enum.map(fn {t, _} -> t.date end) |> Enum.min(Date)
        total_amount = tx.amount |> Decimal.abs() |> Decimal.mult(total)

        {:ok, group} =
          create_installment_group(%{
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
  defp link_and_clean(tx, group, detection, billed_date) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.id == ^tx.id)
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
  def associate_matching_transactions(%InstallmentGroup{} = group) do
    if Regex.match?(~r/\(\d+x · R\$\d+\)$/, group.description_pattern) do
      # Auto-detected groups are handled by detect_and_apply/1, do not auto-associate
      :ok
    else
      # Manual groups: unlink existing and re-associate by pattern
      from(t in Transaction, where: t.installment_group_id == ^group.id)
      |> Repo.update_all(set: [installment_group_id: nil, installment_number: nil])

      pattern = "%#{group.description_pattern}%"

      unlinked_matches =
        Repo.all(
          from t in Transaction,
            where:
              is_nil(t.installment_group_id) and ilike(t.description, ^pattern) and
                t.date >= ^group.start_date,
            order_by: [asc: t.date],
            limit: ^group.installments
        )

      unlinked_matches
      |> Enum.with_index(1)
      |> Enum.each(fn {tx, next_num} ->
        from(t in Transaction, where: t.id == ^tx.id)
        |> Repo.update_all(
          set: [
            installment_group_id: group.id,
            installment_number: next_num,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )
      end)

      :ok
    end
  end

  @doc """
  Dynamically calculates total_amount and installment_amount at read-time if total_amount is nil.
  """
  def load_dynamic_fields(nil), do: nil

  def load_dynamic_fields(%InstallmentGroup{} = group) do
    cond do
      not is_nil(group.total_amount) ->
        inst_val = Decimal.round(Decimal.div(group.total_amount, group.installments), 2)
        %{group | installment_amount: inst_val}

      not is_nil(group.description_pattern) ->
        pattern = "%#{group.description_pattern}%"

        query =
          from t in Transaction,
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
end
