defmodule CashLens.Repo.Migrations.BackfillStableFingerprints do
  @moduledoc """
  Introduces the occurrence-index dedupe scheme and backfills every existing
  transaction's `dedup_key` + `fingerprint` accordingly.

  ## The scheme

  Dedupe identity is the *base key* — `account_id | date | normalized_time |
  integer_cents | normalized_description` — computed by
  `CashLens.Transactions.Transaction.dedup_key/1` (an absent/unparseable time
  normalizes to the stable constant "00:00:00").
  The stored `fingerprint` is `SHA-256("<dedup_key>|<occurrence_index>")`, where
  `occurrence_index` is the 0-based ordinal of a row among all rows sharing its
  base key. The unique index stays on the single `fingerprint` column.

  This makes re-import dedupe stable (the N identical lines of a re-imported
  statement reproduce ordinals 0..N-1 and collide with what's already stored)
  while *preserving* genuinely-distinct identical same-day purchases (they get
  distinct ordinals).

  ## What this migration does

    1. Adds the `dedup_key` column (indexed, for fast occurrence counting).
    2. For every existing row, computes its `dedup_key`, groups rows by it,
       orders each group deterministically (`inserted_at` then `id`) and assigns
       ordinals 0,1,2…; writes the resulting `dedup_key` + `fingerprint`.

  ## NO ROW DELETION, NO MIS-MERGE

  Because each existing row gets a *distinct* ordinal, every row keeps a unique,
  valid fingerprint — legitimate same-day/same-value repeats are preserved
  automatically, with no `:dup:` suffix hack and no `fingerprint_conflict`
  column. The flip side: this migration cannot itself tell a *true* re-import
  duplicate from a *legitimate* repeat (both look like two rows with the same
  base key), so it intentionally preserves ALL rows. Suspected duplicate
  clusters are surfaced for **manual** review with the read-only query in the PR
  notes (`GROUP BY dedup_key HAVING count(*) > 1`). Identification only — never
  automatic deletion.

  ## Rollback (down)

  Drops the `dedup_key` column and restores the legacy fingerprint algorithm
  (time-sensitive, scale-sensitive, raw-trim description) for every row. The
  legacy algorithm can collide if duplicates exist, so `down` writes a unique
  suffixed value for the non-canonical rows of any colliding group to keep the
  unique index satisfiable.
  """
  use Ecto.Migration

  import Ecto.Query

  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  def up do
    alter table(:transactions) do
      add :dedup_key, :string
    end

    create index(:transactions, [:dedup_key])

    flush()

    backfill_with_occurrence_index()
  end

  def down do
    rebuild_legacy_fingerprints()

    drop index(:transactions, [:dedup_key])

    alter table(:transactions) do
      remove :dedup_key
    end
  end

  @doc """
  Re-runs only the data portion of `up` (no DDL). Exposed so the occurrence-index
  backfill is testable against the already-migrated test database without
  re-issuing `ALTER TABLE`.
  """
  def backfill_with_occurrence_index do
    load_rows()
    |> Enum.map(fn row -> {row, Transaction.dedup_key(identity(row))} end)
    # Rows whose identity fields are incomplete keep their current fingerprint.
    |> Enum.reject(fn {_row, key} -> is_nil(key) end)
    |> Enum.group_by(fn {_row, key} -> key end)
    |> Enum.each(fn {key, members} -> assign_group(key, members) end)
  end

  # Each row in a base-key group gets a distinct ordinal -> a distinct,
  # collision-free fingerprint. Order is deterministic so a re-run is idempotent.
  defp assign_group(key, members) do
    members
    |> sort_members()
    |> Enum.with_index()
    |> Enum.each(fn {{row, _key}, index} ->
      fingerprint = Transaction.fingerprint(identity(row), index)
      update_row(row.id, set: [dedup_key: key, fingerprint: fingerprint])
    end)
  end

  # Oldest first, deterministic tie-break on id.
  defp sort_members(members) do
    Enum.sort_by(members, fn {row, _key} -> {row.inserted_at, row.id} end)
  end

  defp identity(row) do
    %{
      account_id: row.account_id,
      date: row.date,
      # Pass `time` through so the backfilled fingerprints match the live
      # `dedup_key/1` algorithm, which folds a normalized time into the base key
      # (absent time -> stable "00:00:00").
      time: row.time,
      description: row.description,
      amount: row.amount
    }
  end

  defp load_rows do
    "transactions"
    |> select([t], %{
      id: type(t.id, :binary_id),
      account_id: type(t.account_id, :binary_id),
      date: t.date,
      time: t.time,
      description: t.description,
      amount: t.amount,
      inserted_at: t.inserted_at
    })
    |> Repo.all()
  end

  defp update_row(id, updates) do
    from(t in "transactions", where: t.id == type(^id, :binary_id))
    |> Repo.update_all(updates)
  end

  # --- legacy restore (down) ----------------------------------------------

  @doc """
  Re-runs only the data portion of `down` (the legacy-fingerprint restore, no
  DDL). Exposed so the rollback path is testable against the migrated test DB.
  """
  def rebuild_legacy_fingerprints do
    load_rows()
    |> Enum.map(fn row -> {row, legacy_fingerprint(row)} end)
    |> Enum.reject(fn {_row, fp} -> is_nil(fp) end)
    |> Enum.group_by(fn {_row, fp} -> fp end)
    |> Enum.each(fn {fp, members} -> assign_legacy_group(fp, members) end)
  end

  defp assign_legacy_group(fp, members) do
    [{canonical, _} | dups] = sort_members(members)

    update_row(canonical.id, set: [fingerprint: fp])

    Enum.each(dups, fn {row, _fp} ->
      update_row(row.id, set: [fingerprint: "#{fp}:dup:#{row.id}"])
    end)
  end

  # The legacy algorithm, inlined so `down` restores exactly what was on disk
  # before this migration (time-sensitive, scale-sensitive, raw-trim desc).
  defp legacy_fingerprint(
         %{date: date, description: desc, amount: amount, account_id: account_id} = row
       )
       when not is_nil(date) and not is_nil(desc) and not is_nil(amount) and
              not is_nil(account_id) do
    legacy_raw(account_id, date, row[:time], amount, desc)
  end

  defp legacy_fingerprint(_), do: nil

  defp legacy_raw(account_id, date, time, amount, desc) do
    time_str = if time, do: Time.to_string(time), else: ""

    account_id_str =
      case account_id do
        <<_::128>> -> Ecto.UUID.load!(account_id)
        other -> other
      end

    raw =
      "#{account_id_str}|#{date}|#{time_str}|#{Decimal.to_string(amount)}|#{String.trim(desc)}"

    :crypto.hash(:sha256, raw) |> Base.encode16()
  end
end
