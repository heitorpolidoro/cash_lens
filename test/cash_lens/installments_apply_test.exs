defmodule CashLens.InstallmentsApplyTest do
  use CashLens.DataCase, async: false

  alias CashLens.Installments
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  defp ourocard_tx(account_id, description, amount, date) do
    transaction_fixture(%{
      account_id: account_id,
      description: description,
      amount: amount,
      date: date
    })
  end

  describe "detect_and_apply/1" do
    setup do
      %{account: account_fixture()}
    end

    test "groups parcels, cleans descriptions and re-dates to the billing month",
         %{account: account} do
      # Real Ourocard OFX reports every parcel on the original purchase date.
      purchase = ~D[2026-01-10]
      t1 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 01/03 SAO JOSE DOSBR", "-100.00", purchase)
      t2 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 02/03 SAO JOSE DOSBR", "-100.00", purchase)
      t3 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 03/03 SAO JOSE DOSBR", "-100.00", purchase)

      assert Installments.detect_and_apply([t1, t2, t3]) == 3

      [group] = Installments.list_installment_groups()
      assert group.description_pattern == "CAPRICHO VEIC (3x · R$100)"
      assert group.installments == 3
      assert group.start_date == purchase
      assert Decimal.equal?(group.total_amount, Decimal.new("300.00"))

      by_number =
        [t1, t2, t3]
        |> Enum.map(&Repo.get!(Transaction, &1.id))
        |> Map.new(&{&1.installment_number, &1})

      assert Enum.all?(Map.values(by_number), &(&1.installment_group_id == group.id))
      assert Enum.all?(Map.values(by_number), &(&1.description == "CAPRICHO VEIC"))

      # Parcel X bills (X - 1) months after the purchase.
      assert by_number[1].date == ~D[2026-01-10]
      assert by_number[2].date == ~D[2026-02-10]
      assert by_number[3].date == ~D[2026-03-10]
    end

    test "preserves the original fingerprint when cleaning/re-dating", %{account: account} do
      # Two parcels bunched on the purchase date → parcel 2 is re-dated to its month.
      ourocard_tx(account.id, "CVS PARC 01/03 CACAPAVA BR", "-50.00", ~D[2026-02-16])
      tx = ourocard_tx(account.id, "CVS PARC 02/03 CACAPAVA BR", "-50.00", ~D[2026-02-16])
      original_fp = Repo.get!(Transaction, tx.id).fingerprint

      Installments.scan_and_apply_all()

      reloaded = Repo.get!(Transaction, tx.id)
      assert reloaded.description == "CVS"
      assert reloaded.date == ~D[2026-03-16]
      assert reloaded.fingerprint == original_fp
    end

    test "keeps original dates for parcels already billed monthly (distinct dates)",
         %{account: account} do
      # Recurring annuity: each parcel already arrives on its real billing date and
      # must NOT be shifted into the future.
      p2 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 02/12 BR", "-22.75", ~D[2025-12-24])
      p3 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 03/12 BR", "-22.75", ~D[2026-01-27])
      p4 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 04/12 BR", "-22.75", ~D[2026-02-24])

      Installments.detect_and_apply([p2, p3, p4])

      assert Repo.get!(Transaction, p2.id).date == ~D[2025-12-24]
      assert Repo.get!(Transaction, p3.id).date == ~D[2026-01-27]
      assert Repo.get!(Transaction, p4.id).date == ~D[2026-02-24]
    end

    test "separates different plans at the same merchant by total and value",
         %{account: account} do
      a =
        ourocard_tx(
          account.id,
          "00030 SH CEN PARC 01/02 SAO JOSE DOSBR",
          "-219.85",
          ~D[2026-03-21]
        )

      b =
        ourocard_tx(
          account.id,
          "00030 SH CEN PARC 01/03 SAO JOSE DOSBR",
          "-166.44",
          ~D[2025-12-15]
        )

      Installments.detect_and_apply([a, b])

      patterns =
        Installments.list_installment_groups()
        |> Enum.map(& &1.description_pattern)
        |> Enum.sort()

      assert patterns == ["00030 SH CEN (2x · R$220)", "00030 SH CEN (3x · R$166)"]
    end

    test "groups same-purchase parcels whose cents differ (rounding remainder)",
         %{account: account} do
      p = ~D[2026-02-11]
      a = ourocard_tx(account.id, "DROGARIA SAO PARC 01/03 SAO JOSE DOSBR", "-191.40", p)
      b = ourocard_tx(account.id, "DROGARIA SAO PARC 02/03 SAO JOSE DOSBR", "-191.39", p)
      c = ourocard_tx(account.id, "DROGARIA SAO PARC 03/03 SAO JOSE DOSBR", "-191.39", p)

      Installments.detect_and_apply([a, b, c])

      # All three land in a single group despite the one-cent difference.
      assert [group] = Installments.list_installment_groups()
      assert group.description_pattern == "DROGARIA SAO (3x · R$191)"
    end

    test "drops parcels billed in a future month (not yet charged)", %{account: account} do
      today = Date.utc_today()
      # Bunched purchase on today's date: parcel 1 = this month (kept), 2 and 3 future.
      p1 = ourocard_tx(account.id, "LOJA Z PARC 01/03 BR", "-30.00", today)
      p2 = ourocard_tx(account.id, "LOJA Z PARC 02/03 BR", "-30.00", today)
      p3 = ourocard_tx(account.id, "LOJA Z PARC 03/03 BR", "-30.00", today)

      Installments.detect_and_apply([p1, p2, p3])

      assert Repo.get(Transaction, p1.id)
      refute Repo.get(Transaction, p2.id)
      refute Repo.get(Transaction, p3.id)
    end

    test "is idempotent: re-running does not duplicate groups", %{account: account} do
      t1 = ourocard_tx(account.id, "LOJA X PARC 01/02 BR", "-10.00", ~D[2026-01-01])
      Installments.detect_and_apply([t1])
      Installments.scan_and_apply_all()

      assert length(Installments.list_installment_groups()) == 1
    end
  end
end
