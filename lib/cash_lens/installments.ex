defmodule CashLens.Installments do
  @moduledoc """
  The Installments context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Transactions.InstallmentDetector
  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of installment groups.
  """
  def list_installment_groups do
    Repo.all(from g in InstallmentGroup, order_by: [desc: g.inserted_at])
  end

  @doc """
  Gets a single installment group.
  """
  def get_installment_group!(id), do: Repo.get!(InstallmentGroup, id)

  @doc """
  Creates an installment group.
  """
  def create_installment_group(attrs \\ %{}) do
    %InstallmentGroup{}
    |> InstallmentGroup.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an installment group.
  """
  def update_installment_group(%InstallmentGroup{} = group, attrs) do
    group
    |> InstallmentGroup.changeset(attrs)
    |> Repo.update()
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
  defp finished?(%{start_date: nil}), do: false

  defp finished?(%{start_date: start_date, installments: installments}) do
    last_billing = add_months(start_date, installments - 1)
    today = Date.utc_today()
    current_month_start = Date.new!(today.year, today.month, 1)
    Date.compare(last_billing, current_month_start) == :lt
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
      |> Enum.reduce(0, fn {{base, total, amount_key}, items}, acc ->
        # When 2+ parcels share one date, the OFX listed them all at the purchase
        # date, so spread each to its billing month (purchase + number-1). When the
        # parcels already have distinct dates (e.g. recurring annuity charges billed
        # monthly), they are already correct and must not be shifted.
        purchase_date = bunched_purchase_date(Enum.map(items, fn {tx, _} -> tx.date end))
        today = Date.utc_today()

        dated =
          Enum.map(items, fn {tx, d} ->
            billed = if purchase_date, do: add_months(purchase_date, d.number - 1), else: tx.date
            {tx, d, billed}
          end)

        # A parcel billed in a future month has not actually been charged yet, so it
        # is not a real transaction — drop it from the database.
        {future, present} =
          Enum.split_with(dated, fn {_tx, _d, billed} -> Date.compare(billed, today) == :gt end)

        Enum.each(future, fn {tx, _d, _billed} -> Repo.delete(tx) end)

        if present == [] do
          acc
        else
          group =
            find_or_create_group(
              base,
              total,
              amount_key,
              Enum.map(present, fn {tx, d, _} -> {tx, d} end)
            )

          Enum.each(present, fn {tx, d, billed} -> link_and_clean(tx, group, d, billed) end)
          acc + length(present)
        end
      end)

    # Re-dating parcels moves them across months, so rebuild the affected accounts'
    # balance chains to keep monthly summaries correct.
    detected
    |> Enum.map(fn {tx, _d} -> tx.account_id end)
    |> Enum.uniq()
    |> Enum.each(&CashLens.Accounting.rebuild_account_balances/1)

    count
  end

  # Rounds the absolute amount to the nearest whole real, as an integer.
  defp amount_key(amount) do
    amount |> Decimal.abs() |> Decimal.round(0) |> Decimal.to_integer()
  end

  # Returns the purchase date when parcels are "bunched" (2+ on the same date, the way
  # the OFX lists a parcelled purchase), or nil when they already have distinct dates.
  defp bunched_purchase_date(dates) do
    case dates |> Enum.frequencies() |> Enum.max_by(fn {_d, c} -> c end, fn -> nil end) do
      {date, count} when count >= 2 -> date
      _ -> nil
    end
  end

  defp find_or_create_group(base, total, amount_key, items) do
    pattern = "#{base} (#{total}x · R$#{amount_key})"

    case Repo.get_by(InstallmentGroup, description_pattern: pattern) do
      nil ->
        {tx, _d} = hd(items)
        # All parcels carry the original purchase date (OFX DTPOSTED), so use it as
        # the group's start date — the basis for projecting the plan's end.
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
  # `fingerprint` — derived from the raw date and description — is preserved and
  # re-importing the same statement still de-duplicates.
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
end
