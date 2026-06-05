defmodule CashLens.Repo.Migrations.BackfillStableFingerprintsTest do
  @moduledoc """
  Exercises the occurrence-index data backfill of the `BackfillStableFingerprints`
  migration against the already-migrated test DB.

  The `dedup_key` column exists because `mix test` runs `ecto.migrate` before the
  suite; we only re-run the data portion here.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Transactions.Transaction

  alias CashLens.Repo.Migrations.BackfillStableFingerprints, as: Backfill

  # Migrations are not in the compile path, so load the module on demand.
  unless Code.ensure_loaded?(Backfill) do
    Code.require_file("priv/repo/migrations/20260603180718_backfill_stable_fingerprints.exs")
  end

  # Inserts a row directly (bypassing the changeset) with a caller-supplied
  # fingerprint and no dedup_key, simulating pre-migration on-disk data.
  defp insert_legacy(account_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          account_id: account_id,
          date: ~D[2026-04-15],
          description: "MERCADO X",
          amount: Decimal.new("100.00"),
          fingerprint: Ecto.UUID.generate(),
          inserted_at: now,
          updated_at: now
        },
        attrs
      )

    {1, _} = Repo.insert_all(Transaction, [row])
    row.id
  end

  defp reload(id), do: Repo.get!(Transaction, id)

  test "rows sharing a base key are preserved and given distinct occurrence indices" do
    account = account_fixture()

    # Three rows that are distinct under the legacy fingerprint (amount scale /
    # accents / whitespace) but share ONE base key under the new algorithm.
    # All three are date-only (time nil), so they normalize to the stable
    # 00:00:00 default and collapse onto a single base key — exactly the
    # re-export drift the new scheme must collapse.
    older = ~U[2026-01-01 10:00:00Z]
    middle = ~U[2026-01-02 10:00:00Z]
    newer = ~U[2026-01-03 10:00:00Z]

    id0 =
      insert_legacy(account.id, %{
        time: nil,
        amount: Decimal.new("100.00"),
        description: "MERCADO SÃO X",
        inserted_at: older
      })

    id1 =
      insert_legacy(account.id, %{
        time: nil,
        amount: Decimal.new("100.0"),
        description: "mercado sao x",
        inserted_at: middle
      })

    id2 =
      insert_legacy(account.id, %{
        time: nil,
        amount: Decimal.new("100"),
        description: "MERCADO   SAO   X",
        inserted_at: newer
      })

    assert Repo.aggregate(Transaction, :count) == 3

    # Must not raise on the colliding group.
    Backfill.backfill_with_occurrence_index()

    # No row deleted.
    assert Repo.aggregate(Transaction, :count) == 3

    identity = %{
      account_id: account.id,
      date: ~D[2026-04-15],
      description: "MERCADO SÃO X",
      amount: Decimal.new("100.00")
    }

    expected_key = Transaction.dedup_key(identity)

    row0 = reload(id0)
    row1 = reload(id1)
    row2 = reload(id2)

    # All three share the same dedup_key...
    assert row0.dedup_key == expected_key
    assert row1.dedup_key == expected_key
    assert row2.dedup_key == expected_key

    # ...but get distinct occurrence indices ordered by inserted_at, then id.
    assert row0.fingerprint == Transaction.fingerprint(identity, 0)
    assert row1.fingerprint == Transaction.fingerprint(identity, 1)
    assert row2.fingerprint == Transaction.fingerprint(identity, 2)

    # All distinct -> the unique fingerprint index is satisfiable.
    fps = [row0.fingerprint, row1.fingerprint, row2.fingerprint]
    assert length(Enum.uniq(fps)) == 3
  end

  test "a lone row gets occurrence index 0 and its dedup_key" do
    account = account_fixture()

    id =
      insert_legacy(account.id, %{
        description: "UNIQUE CHARGE",
        amount: Decimal.new("42.00")
      })

    Backfill.backfill_with_occurrence_index()

    row = reload(id)

    identity = %{
      account_id: account.id,
      date: row.date,
      description: "UNIQUE CHARGE",
      amount: Decimal.new("42.00")
    }

    assert row.dedup_key == Transaction.dedup_key(identity)
    assert row.fingerprint == Transaction.fingerprint(identity, 0)
  end

  test "down restores legacy fingerprints, suffixing colliding rows" do
    account = account_fixture()
    older = ~U[2026-01-01 10:00:00Z]
    newer = ~U[2026-01-02 10:00:00Z]

    # Two rows identical under the LEGACY algorithm (same date/amount/time/desc):
    # the canonical (oldest) keeps the clean legacy fp, the other is suffixed.
    id_canonical =
      insert_legacy(account.id, %{
        description: "LEGACY DUP",
        amount: Decimal.new("10.00"),
        time: ~T[08:00:00],
        inserted_at: older
      })

    id_dup =
      insert_legacy(account.id, %{
        description: "LEGACY DUP",
        amount: Decimal.new("10.00"),
        time: ~T[08:00:00],
        inserted_at: newer
      })

    # A lone row that simply gets the clean legacy fp.
    id_solo =
      insert_legacy(account.id, %{description: "LEGACY SOLO", amount: Decimal.new("3.00")})

    Backfill.rebuild_legacy_fingerprints()

    canonical = reload(id_canonical)
    dup = reload(id_dup)
    solo = reload(id_solo)

    refute canonical.fingerprint == nil
    assert dup.fingerprint == "#{canonical.fingerprint}:dup:#{id_dup}"
    refute solo.fingerprint == nil
    refute solo.fingerprint == canonical.fingerprint
  end

  test "backfill is idempotent" do
    account = account_fixture()

    id =
      insert_legacy(account.id, %{
        description: "REPEAT SAFE",
        amount: Decimal.new("9.99")
      })

    Backfill.backfill_with_occurrence_index()
    first = reload(id)

    Backfill.backfill_with_occurrence_index()
    second = reload(id)

    assert first.fingerprint == second.fingerprint
    assert first.dedup_key == second.dedup_key
  end
end
