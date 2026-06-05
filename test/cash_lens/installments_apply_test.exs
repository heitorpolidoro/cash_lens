defmodule CashLens.InstallmentsApplyTest do
  use CashLens.DataCase, async: false

  import Ecto.Query

  alias CashLens.Categories
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
      # Every parcel of a single purchase carries the same DTPOSTED (the purchase
      # date); each is re-dated to add_months(purchase, number - 1).
      purchase = ~D[2026-01-10]
      t1 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 01/03 SAO JOSE DOSBR", "-100.00", purchase)
      t2 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 02/03 SAO JOSE DOSBR", "-100.00", purchase)
      t3 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 03/03 SAO JOSE DOSBR", "-100.00", purchase)

      assert Installments.detect_and_apply([t1, t2, t3]) == 3

      [group] = Installments.list_installment_groups()
      assert group.description_pattern == "CAPRICHO VEIC (3x · R$100)"
      assert group.installments == 3
      # start_date is the inferred purchase month (parcel 1's billing month).
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

    test "always re-dates each parcel from its own DTPOSTED (distinct dates)",
         %{account: account} do
      # "PARC xx/yy" always denotes a single installment purchase: each parcel is
      # re-dated to add_months(its own DTPOSTED, number - 1), regardless of whether
      # the parcels share a date or arrive with distinct dates.
      p2 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 02/12 BR", "-22.75", ~D[2025-12-24])
      p3 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 03/12 BR", "-22.75", ~D[2026-01-27])
      p4 = ourocard_tx(account.id, "ANUIDADE ADC-PARC 04/12 BR", "-22.75", ~D[2026-02-24])

      Installments.detect_and_apply([p2, p3, p4])

      # parcel N bills (N - 1) months after its own DTPOSTED.
      assert Repo.get!(Transaction, p2.id).date == ~D[2026-01-24]
      assert Repo.get!(Transaction, p3.id).date == ~D[2026-03-27]
      assert Repo.get!(Transaction, p4.id).date == ~D[2026-05-24]
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

    test "applies nothing when every parcel bills in a future month", %{account: account} do
      # Two parcels bunched on a future date: every billing month is in the future,
      # so all parcels are dropped and no group is created.
      future = Date.utc_today() |> Date.add(40)
      p1 = ourocard_tx(account.id, "FUTURO PARC 01/02 BR", "-30.00", future)
      p2 = ourocard_tx(account.id, "FUTURO PARC 02/02 BR", "-30.00", future)

      assert Installments.detect_and_apply([p1, p2]) == 0
      assert Installments.list_installment_groups() == []
      refute Repo.get(Transaction, p1.id)
      refute Repo.get(Transaction, p2.id)
    end

    test "reuses an existing group for a parcel imported later", %{account: account} do
      p = ~D[2026-01-12]
      a = ourocard_tx(account.id, "CVS PARC 01/03 CACAPAVA BR", "-50.00", p)
      b = ourocard_tx(account.id, "CVS PARC 02/03 CACAPAVA BR", "-50.00", p)
      assert Installments.detect_and_apply([a, b]) == 2
      [group] = Installments.list_installment_groups()

      # Parcel 3 arrives in a later statement (distinct, past date) and must attach
      # to the already-created group instead of spawning a new one.
      c = ourocard_tx(account.id, "CVS PARC 03/03 CACAPAVA BR", "-50.00", ~D[2026-03-12])
      assert Installments.detect_and_apply([c]) == 1

      assert [reloaded] = Installments.list_installment_groups()
      assert reloaded.id == group.id

      reloaded_c = Repo.get!(Transaction, c.id)
      assert reloaded_c.installment_group_id == group.id
      # parcel 3 bills 2 months after its own DTPOSTED (2026-03-12 → 2026-05-12).
      assert reloaded_c.date == ~D[2026-05-12]
    end

    test "is idempotent: re-running does not duplicate groups", %{account: account} do
      t1 = ourocard_tx(account.id, "LOJA X PARC 01/02 BR", "-10.00", ~D[2026-01-01])
      Installments.detect_and_apply([t1])
      Installments.scan_and_apply_all()

      assert length(Installments.list_installment_groups()) == 1
    end

    test "re-dates parcels from different purchases each by its own DTPOSTED",
         %{account: account} do
      # Real "Próxima Fatura" shape: each parcel of a single purchase shows up on a
      # distinct DTPOSTED (the purchase date). Two unrelated purchases here:
      #   ELETRO  PARC 08/10 @ 2025-10-15 → add_months(7) → 2026-05-15
      #   VIAGEM  PARC 04/04 @ 2026-01-20 → add_months(3) → 2026-04-20
      eletro =
        ourocard_tx(account.id, "ELETRO PARC 08/10 SAO PAULO BR", "-300.00", ~D[2025-10-15])

      viagem =
        ourocard_tx(account.id, "VIAGEM PARC 04/04 SAO PAULO BR", "-150.00", ~D[2026-01-20])

      assert Installments.detect_and_apply([eletro, viagem]) == 2

      assert Repo.get!(Transaction, eletro.id).date == ~D[2026-05-15]
      assert Repo.get!(Transaction, viagem.id).date == ~D[2026-04-20]
    end

    test "re-importing the same fatura yields no duplicates and stable dates",
         %{account: account} do
      purchase = ~D[2026-01-10]
      t1 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 01/03 SAO JOSE DOSBR", "-100.00", purchase)
      t2 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 02/03 SAO JOSE DOSBR", "-100.00", purchase)
      t3 = ourocard_tx(account.id, "CAPRICHO VEIC PARC 03/03 SAO JOSE DOSBR", "-100.00", purchase)

      assert Installments.detect_and_apply([t1, t2, t3]) == 3

      dates_after_first =
        [t1, t2, t3]
        |> Enum.map(&Repo.get!(Transaction, &1.id).date)

      # Re-running detection (e.g. a re-import) must not duplicate groups or shift dates.
      Installments.scan_and_apply_all()

      assert length(Installments.list_installment_groups()) == 1

      dates_after_second =
        [t1, t2, t3]
        |> Enum.map(&Repo.get!(Transaction, &1.id).date)

      assert dates_after_second == dates_after_first
      assert dates_after_first == [~D[2026-01-10], ~D[2026-02-10], ~D[2026-03-10]]
    end
  end

  describe "category backfill on grouping" do
    setup do
      %{acc: account_fixture()}
    end

    # The Category changeset auto-generates the slug from the name and only casts
    # name/keywords/type, so we pass a unique name and (optionally) keywords.
    defp make_category(attrs) do
      attrs =
        attrs
        |> Map.delete(:slug)
        |> Map.put_new(:name, "Cat #{System.unique_integer([:positive])}")

      {:ok, cat} = Categories.create_category(attrs)
      cat
    end

    test "uncategorized parcel inherits a categorized sibling's category", %{acc: acc} do
      cat = make_category(%{name: "Saúde #{System.unique_integer([:positive])}"})

      t1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-48.00",
          description: "EC FARMA PARC 01/03 BR",
          date: ~D[2026-01-10],
          category_id: cat.id
        })

      _t2 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-48.00",
          description: "EC FARMA PARC 02/03 BR",
          date: ~D[2026-01-10]
        })

      Installments.detect_and_apply(Repo.all(Transaction))

      cats =
        Repo.all(
          from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id
        )

      assert cats != []
      assert Enum.all?(cats, &(&1 == cat.id))
      # sanity: the originally-categorized one is unchanged
      assert Repo.get(Transaction, t1.id).category_id == cat.id
    end

    test "all-uncategorized group is categorized via cleaned description keyword", %{acc: acc} do
      cat =
        make_category(%{
          name: "Mercado #{System.unique_integer([:positive])}",
          keywords: "EC FARMA"
        })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 01/03 BR",
        date: ~D[2026-01-10]
      })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 02/03 BR",
        date: ~D[2026-01-10]
      })

      Installments.detect_and_apply(Repo.all(Transaction))

      cats =
        Repo.all(
          from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id
        )

      assert cats != []
      assert Enum.all?(cats, &(&1 == cat.id))
    end

    test "existing category is never overwritten", %{acc: acc} do
      keep = make_category(%{name: "Manual #{System.unique_integer([:positive])}"})

      _other =
        make_category(%{
          name: "Auto #{System.unique_integer([:positive])}",
          keywords: "EC FARMA"
        })

      t1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-48.00",
          description: "EC FARMA PARC 01/03 BR",
          date: ~D[2026-01-10],
          category_id: keep.id
        })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "EC FARMA PARC 02/03 BR",
        date: ~D[2026-01-10]
      })

      Installments.detect_and_apply(Repo.all(Transaction))

      # t1 keeps its manual category, not overwritten by the keyword-matched `other`.
      assert Repo.get(Transaction, t1.id).category_id == keep.id
    end

    test "group with no category and no keyword match stays uncategorized", %{acc: acc} do
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "ZZZ NOMATCH PARC 01/02 BR",
        date: ~D[2026-01-10]
      })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-48.00",
        description: "ZZZ NOMATCH PARC 02/02 BR",
        date: ~D[2026-01-10]
      })

      Installments.detect_and_apply(Repo.all(Transaction))

      cats =
        Repo.all(
          from t in Transaction, where: not is_nil(t.installment_group_id), select: t.category_id
        )

      assert cats != []
      assert Enum.all?(cats, &is_nil/1)
    end
  end
end
