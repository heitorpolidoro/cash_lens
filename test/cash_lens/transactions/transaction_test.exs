defmodule CashLens.Transactions.TransactionTest do
  use CashLens.DataCase, async: true

  alias CashLens.Transactions.Transaction

  test "decode_account_id" do
    assert Ecto.UUID.cast!(Ecto.UUID.generate()) |> is_binary()

    invalid_binary = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>

    changeset =
      Transaction.changeset(%Transaction{}, %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: invalid_binary
      })

    assert Ecto.UUID.cast!(changeset.changes.account_id)
  end

  describe "fingerprint/1 stability" do
    @account_id "11111111-1111-1111-1111-111111111111"

    defp fp(attrs) do
      base = %{
        date: ~D[2026-04-15],
        description: "MERCADO X",
        amount: Decimal.new("100.00"),
        account_id: @account_id
      }

      Transaction.fingerprint(Map.merge(base, attrs))
    end

    test "is invariant to amount scale" do
      a = fp(%{amount: Decimal.new("100")})
      b = fp(%{amount: Decimal.new("100.0")})
      c = fp(%{amount: Decimal.new("100.00")})

      assert a == b
      assert b == c
    end

    test "distinguishes genuinely different amounts" do
      refute fp(%{amount: Decimal.new("100.00")}) == fp(%{amount: Decimal.new("100.01")})
      refute fp(%{amount: Decimal.new("100.00")}) == fp(%{amount: Decimal.new("-100.00")})
    end

    test "absent and unparseable time both map to the stable 00:00:00 default" do
      # An absent time (nil) and an explicit midnight must produce the SAME
      # fingerprint: the stable default is what prevents the "value vs empty"
      # flip across re-exports that originally caused duplication.
      assert fp(%{}) == fp(%{time: ~T[00:00:00]})
    end

    test "a real distinct time is now a discriminator" do
      # With time reintroduced, two charges that differ only by a real time get
      # distinct fingerprints (debit transactions carry reliable times).
      refute fp(%{time: ~T[12:30:00]}) == fp(%{time: ~T[09:00:00]})
      refute fp(%{time: ~T[12:30:00]}) == fp(%{time: nil})
    end

    test "is invariant to description whitespace differences" do
      a = fp(%{description: "MERCADO   X"})
      b = fp(%{description: "  MERCADO X  "})
      c = fp(%{description: "MERCADO\tX"})

      assert a == b
      assert b == c
    end

    test "is invariant to description case differences" do
      assert fp(%{description: "Mercado X"}) == fp(%{description: "MERCADO X"})
    end

    test "is invariant to description diacritics (accents)" do
      assert fp(%{description: "PADARIA SÃO JOSÉ"}) == fp(%{description: "PADARIA SAO JOSE"})
      assert fp(%{description: "FARMÁCIA"}) == fp(%{description: "FARMACIA"})
    end

    test "distinguishes genuinely different descriptions" do
      refute fp(%{description: "MERCADO X"}) == fp(%{description: "MERCADO Y"})
    end

    test "cross-parser same charge converges (OFX padded vs CSV scraped)" do
      ofx_variant = fp(%{description: "SCHOOL OF ROCK SAO JOSE DOS BR", time: ~T[00:00:00]})
      csv_variant = fp(%{description: "school of rock são josé dos  br", time: nil})

      assert ofx_variant == csv_variant
    end

    test "returns nil when required fields are missing" do
      assert Transaction.fingerprint(%{date: ~D[2026-04-15]}) == nil
    end

    test "accepts a string amount" do
      assert fp(%{amount: "100.00"}) == fp(%{amount: Decimal.new("100")})
    end
  end

  describe "occurrence-index fingerprinting" do
    @account_id "11111111-1111-1111-1111-111111111111"

    defp identity(attrs) do
      Map.merge(
        %{
          date: ~D[2026-04-15],
          description: "MERCADO X",
          amount: Decimal.new("100.00"),
          account_id: @account_id
        },
        attrs
      )
    end

    test "distinct occurrence indices produce distinct fingerprints" do
      base = identity(%{})

      f0 = Transaction.fingerprint(base, 0)
      f1 = Transaction.fingerprint(base, 1)
      f2 = Transaction.fingerprint(base, 2)

      assert length(Enum.uniq([f0, f1, f2])) == 3
    end

    test "the same occurrence index is stable across calls" do
      base = identity(%{})
      assert Transaction.fingerprint(base, 1) == Transaction.fingerprint(base, 1)
    end

    test "default index is 0" do
      base = identity(%{})
      assert Transaction.fingerprint(base) == Transaction.fingerprint(base, 0)
    end

    test "occurrence index is folded onto the dedup_key, not the raw fields" do
      base = identity(%{})
      expected = :crypto.hash(:sha256, "#{Transaction.dedup_key(base)}|3") |> Base.encode16()
      assert Transaction.fingerprint(base, 3) == expected
    end

    test "fingerprint at any index is nil when identity is incomplete" do
      assert Transaction.fingerprint(%{date: ~D[2026-04-15]}, 5) == nil
    end
  end

  describe "dedup_key/1" do
    @account_id "11111111-1111-1111-1111-111111111111"

    defp key(attrs) do
      base = %{
        date: ~D[2026-04-15],
        description: "MERCADO X",
        amount: Decimal.new("100.00"),
        account_id: @account_id
      }

      Transaction.dedup_key(Map.merge(base, attrs))
    end

    test "is invariant to amount scale, whitespace, case and diacritics" do
      assert key(%{amount: Decimal.new("100")}) == key(%{amount: Decimal.new("100.00")})
      assert key(%{description: "  mercado   x "}) == key(%{description: "MERCADO X"})
      assert key(%{description: "MÉRCÁDO X"}) == key(%{description: "MERCADO X"})
    end

    test "absent/nil time normalizes to the stable 00:00:00 default" do
      assert key(%{time: nil}) == key(%{time: ~T[00:00:00]})
    end

    test "a real distinct time changes the dedup key" do
      refute key(%{time: ~T[12:30:00]}) == key(%{time: nil})
      refute key(%{time: ~T[12:30:00]}) == key(%{time: ~T[09:00:00]})
    end

    test "time is zero-padded to a single canonical HH:MM:SS form" do
      # Both renderings of 09:05:03 must converge on one canonical string so the
      # key never drifts between parsers/exports.
      assert key(%{time: ~T[09:05:03]}) == key(%{time: ~T[09:05:03.000000]})
      assert String.contains?(key(%{time: ~T[09:05:03]}), "|09:05:03|")
    end

    test "a string time (form param style) is parsed and normalized" do
      # Form params arrive as ISO-8601 strings before the changeset casts them;
      # a valid string time must match the equivalent Time struct.
      assert key(%{time: "09:05:03"}) == key(%{time: ~T[09:05:03]})
    end

    test "an unparseable string time falls back to the stable default" do
      # Garbage/empty time strings must collapse to 00:00:00, never flipping the
      # key between runs.
      assert key(%{time: "not-a-time"}) == key(%{time: nil})
      assert key(%{time: ""}) == key(%{time: ~T[00:00:00]})
    end

    test "distinguishes different amounts and descriptions" do
      refute key(%{amount: Decimal.new("100.01")}) == key(%{})
      refute key(%{description: "MERCADO Y"}) == key(%{})
    end

    test "installment parcels self-disambiguate via the PARC marker" do
      refute key(%{description: "TRILHARES EST PARC 03/09"}) ==
               key(%{description: "TRILHARES EST PARC 04/09"})
    end

    test "returns nil when identity fields are missing" do
      assert Transaction.dedup_key(%{date: ~D[2026-04-15]}) == nil
    end

    test "accepts a raw 16-byte binary account_id (decodes to UUID string)" do
      uuid = "11111111-1111-1111-1111-111111111111"
      raw = Ecto.UUID.dump!(uuid)

      assert key(%{account_id: raw}) == key(%{account_id: uuid})
    end

    test "accepts an ISO-8601 string date (form param style)" do
      assert key(%{date: "2026-04-15"}) == key(%{date: ~D[2026-04-15]})
    end
  end

  describe "changeset fingerprint" do
    test "changeset sets the same fingerprint produced by fingerprint/1" do
      attrs = %{
        date: ~D[2026-04-15],
        description: "MERCADO X",
        amount: "100.00",
        account_id: "11111111-1111-1111-1111-111111111111"
      }

      changeset = Transaction.changeset(%Transaction{}, attrs)
      assert changeset.changes.fingerprint == Transaction.fingerprint(attrs)
    end

    test "two changesets that differ only by amount scale collide" do
      base = %{
        date: ~D[2026-04-15],
        description: "MERCADO X",
        account_id: "11111111-1111-1111-1111-111111111111"
      }

      cs1 = Transaction.changeset(%Transaction{}, Map.put(base, :amount, "100"))
      cs2 = Transaction.changeset(%Transaction{}, Map.put(base, :amount, "100.00"))

      assert cs1.changes.fingerprint == cs2.changes.fingerprint
    end
  end
end
