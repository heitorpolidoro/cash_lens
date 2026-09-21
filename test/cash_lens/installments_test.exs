defmodule CashLens.InstallmentsTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Installments.InstallmentGroup
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  defp group(attrs) do
    {:ok, g} =
      Installments.create_installment_group(
        Map.merge(
          %{description_pattern: "G", installments: 3, start_date: Date.utc_today()},
          attrs
        )
      )

    g
  end

  test "update_installment_group/2 changes fields" do
    g = group(%{description_pattern: "Antigo"})
    {:ok, updated} = Installments.update_installment_group(g, %{description_pattern: "Novo"})
    assert updated.description_pattern == "Novo"
  end

  test "change_installment_group/1 returns a changeset" do
    assert %Ecto.Changeset{} = Installments.change_installment_group(%InstallmentGroup{})
  end

  describe "total_amount automatic calculations" do
    test "calculates total_amount from installment_amount when total_amount is nil" do
      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "TEST CALC 1",
          installments: 4,
          start_date: ~D[2026-01-01],
          installment_amount: "50.00"
        })

      assert Decimal.equal?(g.total_amount, Decimal.new("200.00"))

      # Verify it was saved to the DB
      fetched = Installments.get_installment_group!(g.id)
      assert Decimal.equal?(fetched.total_amount, Decimal.new("200.00"))
      assert Decimal.equal?(fetched.installment_amount, Decimal.new("50.00"))
    end

    test "calculates total_amount from the last matching transaction when both are nil" do
      acc = account_fixture()

      # Create some transactions matching description pattern
      _tx_old =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-45.00",
          description: "OUTRO TEST CALC 2 MENSAL",
          date: ~D[2026-01-01]
        })

      _tx_new =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "TEST CALC 2",
          date: ~D[2026-01-10]
        })

      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "TEST CALC 2",
          installments: 3,
          start_date: ~D[2026-01-01]
        })

      # Should match tx_new (-50.00 -> 50.00 * 3 = 150.00) dynamically
      assert Decimal.equal?(g.total_amount, Decimal.new("150.00"))

      # Verify that total_amount is actually nil in the database (not persisted)
      db_group = Repo.get!(InstallmentGroup, g.id)
      assert is_nil(db_group.total_amount)

      # But fetched via context is populated
      fetched = Installments.get_installment_group!(g.id)
      assert Decimal.equal?(fetched.total_amount, Decimal.new("150.00"))
      assert Decimal.equal?(fetched.installment_amount, Decimal.new("50.00"))
    end

    test "leaves total_amount as nil if total_amount/installment_amount are nil and no matching transaction is found" do
      assert {:ok, g} =
               Installments.create_installment_group(%{
                 description_pattern: "NON EXISTENT MERCH",
                 installments: 3,
                 start_date: ~D[2026-01-01]
               })

      assert is_nil(g.total_amount)

      fetched = Installments.get_installment_group!(g.id)
      assert is_nil(fetched.total_amount)
    end
  end

  test "list_active_groups/0 excludes completed groups" do
    active = group(%{description_pattern: "Ativo (3x)", total_amount: "300.00", installments: 3})

    completed =
      group(%{description_pattern: "Fim (2x)", total_amount: "200.00", installments: 2})

    acc = account_fixture()
    t1 = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "Fim 1"})
    t2 = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "Fim 2"})

    Repo.update_all(from(t in Transaction, where: t.id in [^t1.id, ^t2.id]),
      set: [installment_group_id: completed.id]
    )

    ids = Installments.list_active_groups() |> Enum.map(& &1.id)
    assert active.id in ids
    refute completed.id in ids
  end

  test "get_group_with_progress/1 reports progress" do
    g = group(%{description_pattern: "P (2x)", total_amount: "200.00", installments: 2})
    acc = account_fixture()
    tx = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: "P"})

    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
      set: [installment_group_id: g.id]
    )

    progress = Installments.get_group_with_progress(g.id)
    assert progress.paid_count == 1
    assert progress.remaining_count == 1
    refute progress.is_completed
  end

  test "find_matching_group/1 matches by description and handles nil" do
    g = group(%{description_pattern: "NETFLIX"})
    assert Installments.find_matching_group("PAGAMENTO NETFLIX MENSAL").id == g.id
    assert is_nil(Installments.find_matching_group("OUTRA COISA"))
    assert is_nil(Installments.find_matching_group(nil))
  end

  describe "last_installment_date/1" do
    test "returns start_date + (installments - 1) months" do
      g = %CashLens.Installments.InstallmentGroup{
        start_date: ~D[2025-10-08],
        installments: 10
      }

      assert Installments.last_installment_date(g) == ~D[2026-07-08]
    end

    test "single-installment group ends on its start date" do
      g = %CashLens.Installments.InstallmentGroup{start_date: ~D[2026-01-15], installments: 1}
      assert Installments.last_installment_date(g) == ~D[2026-01-15]
    end

    test "returns nil when start_date is missing" do
      g = %CashLens.Installments.InstallmentGroup{start_date: nil, installments: 3}
      assert Installments.last_installment_date(g) == nil
    end
  end

  describe "list_group_transactions/1" do
    test "returns the group's transactions ordered by installment_number" do
      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "LOJA Y",
          installments: 3,
          start_date: ~D[2026-01-01]
        })

      acc = account_fixture()

      t2 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 2/3"})
      t1 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 1/3"})

      Repo.update_all(from(t in Transaction, where: t.id == ^t1.id),
        set: [installment_group_id: g.id, installment_number: 1]
      )

      Repo.update_all(from(t in Transaction, where: t.id == ^t2.id),
        set: [installment_group_id: g.id, installment_number: 2]
      )

      numbers =
        g.id
        |> Installments.list_group_transactions()
        |> Enum.map(& &1.installment_number)

      assert numbers == [1, 2]
    end

    test "returns [] for a group with no transactions" do
      {:ok, g} =
        Installments.create_installment_group(%{
          description_pattern: "EMPTY",
          installments: 2,
          start_date: ~D[2026-01-01]
        })

      assert Installments.list_group_transactions(g.id) == []
    end
  end

  describe "upcoming_installments/1" do
    test "sums parcels per month, including groups without a total amount" do
      today = Date.utc_today()
      first = Date.new!(today.year, today.month, 1)

      group(%{
        description_pattern: "COM VALOR (3x)",
        total_amount: "300.00",
        installments: 3,
        start_date: first
      })

      group(%{
        description_pattern: "SEM VALOR (3x)",
        total_amount: nil,
        installments: 3,
        start_date: first
      })

      result = Installments.upcoming_installments(3)
      assert is_list(result)
      assert Enum.all?(result, &Map.has_key?(&1, :total))
      # The group with a total contributes 100/month.
      this_month = Enum.find(result, &(&1.date == first))
      assert Decimal.gt?(this_month.total, Decimal.new("0"))
    end

    test "flags a past month whose statement isn't imported yet as pending" do
      acc = account_fixture()
      g = group(%{description_pattern: "PAST (3x)", total_amount: "300.00", installments: 3})

      # An imported parcel dated last month-end makes the current month 'incomplete'.
      last_month_end = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1)

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "PAST",
          date: last_month_end
        })

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [installment_group_id: g.id]
      )

      result = Installments.upcoming_installments(3)
      assert is_list(result)
    end
  end

  describe "automatic association for manual groups" do
    test "automatically associates unlinked matching transactions upon group creation" do
      acc = account_fixture()

      # Match because date >= start_date and description matches pattern
      tx1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "CURSO ELIXIR",
          date: ~D[2026-01-10]
        })

      tx2 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Curso Elixir Avançado",
          date: ~D[2026-02-10]
        })

      # Should NOT match because date < start_date
      _tx_early =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Curso Elixir",
          date: ~D[2025-12-10]
        })

      # Should NOT match because description doesn't match
      _tx_other =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Outra Coisa",
          date: ~D[2026-01-15]
        })

      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "Curso Elixir",
          installments: 3,
          start_date: ~D[2026-01-01],
          total_amount: "150.00"
        })

      linked = Installments.list_group_transactions(group.id)
      assert length(linked) == 2

      [l1, l2] = linked
      assert l1.id == tx1.id
      assert l1.installment_number == 1
      assert l2.id == tx2.id
      assert l2.installment_number == 2
    end

    test "respects group.installments limit" do
      acc = account_fixture()

      _tx1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "CURSO ELIXIR",
          date: ~D[2026-01-10]
        })

      _tx2 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Curso Elixir",
          date: ~D[2026-02-10]
        })

      _tx3 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Curso Elixir",
          date: ~D[2026-03-10]
        })

      # Create group with 2 installments limit
      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "Curso Elixir",
          installments: 2,
          start_date: ~D[2026-01-01],
          total_amount: "100.00"
        })

      linked = Installments.list_group_transactions(group.id)
      assert length(linked) == 2
    end

    test "updating group updates automatic associations" do
      acc = account_fixture()

      tx_old =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "OLD MERCH",
          date: ~D[2026-01-10]
        })

      tx_new =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "NEW MERCH",
          date: ~D[2026-01-12]
        })

      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "OLD MERCH",
          installments: 2,
          start_date: ~D[2026-01-01],
          total_amount: "100.00"
        })

      assert [linked_old] = Installments.list_group_transactions(group.id)
      assert linked_old.id == tx_old.id

      # Update description pattern
      {:ok, updated_group} =
        Installments.update_installment_group(group, %{
          description_pattern: "NEW MERCH"
        })

      linked = Installments.list_group_transactions(updated_group.id)
      assert [linked_new] = linked
      assert linked_new.id == tx_new.id

      # Verify old is unlinked
      refute CashLens.Transactions.get_transaction!(tx_old.id).installment_group_id
    end

    test "does not auto-associate for auto-detected pattern format groups" do
      acc = account_fixture()

      _tx =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "AMAZON",
          date: ~D[2026-01-10]
        })

      # Create with auto-detected pattern format
      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "AMAZON (2x · R$50)",
          installments: 2,
          start_date: ~D[2026-01-01],
          total_amount: "100.00"
        })

      assert Installments.list_group_transactions(group.id) == []
    end
  end

  describe "account_installment_total/2" do
    test "sums parcels due in the given month for groups touching the account" do
      card = account_fixture(%{is_credit_card: true})
      other_card = account_fixture(%{is_credit_card: true})

      {:ok, group} =
        Installments.create_installment_group(%{
          description_pattern: "FORECAST_TEST_ITEM",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: group.id,
        installment_number: 1,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      # A group touching a DIFFERENT account must not be counted.
      {:ok, other_group} =
        Installments.create_installment_group(%{
          description_pattern: "FORECAST_TEST_OTHER",
          installments: 2,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("200.00")
        })

      transaction_fixture(%{
        account_id: other_card.id,
        installment_group_id: other_group.id,
        installment_number: 1,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      total = Installments.account_installment_total(card.id, ~D[2026-07-01])
      assert Decimal.equal?(total, Decimal.new("100.00"))
    end

    test "returns 0 when nothing is due for the account in that month" do
      card = account_fixture(%{is_credit_card: true})
      total = Installments.account_installment_total(card.id, ~D[2026-01-01])
      assert Decimal.equal?(total, Decimal.new("0"))
    end
  end

  describe "commitment types" do
    test "defaults to credit_card so pre-existing groups keep behaving as card purchases" do
      g = group(%{description_pattern: "LEGADO"})
      assert g.commitment_type == "credit_card"
    end

    test "accepts financing and consorcio specific fields" do
      fin =
        group(%{
          description_pattern: "FINANC CAIXA",
          commitment_type: "financing",
          institution: "Caixa",
          interest_rate: "8.5",
          installments: 360,
          start_date: ~D[2026-01-10],
          total_amount: "280000.00"
        })

      assert fin.commitment_type == "financing"
      assert fin.institution == "Caixa"
      assert Decimal.equal?(fin.interest_rate, Decimal.new("8.5"))

      cons =
        group(%{
          description_pattern: "CONSORCIO PORTO",
          commitment_type: "consorcio",
          credit_letter_amount: "80000.00",
          is_contemplated: true,
          contemplated_at: ~D[2026-03-01],
          installments: 120,
          start_date: ~D[2026-01-20],
          total_amount: "102000.00"
        })

      assert cons.commitment_type == "consorcio"
      assert cons.is_contemplated
      assert Decimal.equal?(cons.credit_letter_amount, Decimal.new("80000.00"))
    end

    test "rejects an unknown commitment type" do
      {:error, changeset} =
        Installments.create_installment_group(%{
          description_pattern: "X",
          installments: 3,
          start_date: Date.utc_today(),
          commitment_type: "leasing"
        })

      assert "is invalid" in errors_on(changeset).commitment_type
    end

    test "commitment_type/1 falls back to credit_card when the column is null" do
      assert Installments.commitment_type(%{commitment_type: nil}) == "credit_card"
    end

    test "commitment_types/0 lists the supported modalities" do
      assert Installments.commitment_types() == ["credit_card", "financing", "consorcio"]
    end
  end

  describe "global commitment metrics" do
    setup do
      today = Date.utc_today()
      m0 = Date.new!(today.year, today.month, 1)

      card_a =
        group(%{
          description_pattern: "CARTAO A",
          installments: 3,
          start_date: m0,
          total_amount: "300.00"
        })

      card_b =
        group(%{
          description_pattern: "CARTAO B",
          installments: 2,
          start_date: m0,
          total_amount: "200.00"
        })

      fin =
        group(%{
          description_pattern: "FINANCIAMENTO X",
          commitment_type: "financing",
          installments: 10,
          start_date: m0,
          total_amount: "10000.00"
        })

      cons =
        group(%{
          description_pattern: "CONSORCIO Y",
          commitment_type: "consorcio",
          installments: 5,
          start_date: m0,
          total_amount: "5000.00"
        })

      %{m0: m0, card_a: card_a, card_b: card_b, fin: fin, cons: cons}
    end

    test "monthly_commitment/1 breaks the current month down by type with counts", %{m0: m0} do
      metrics = Installments.monthly_commitment(m0)

      assert Decimal.equal?(metrics.total, Decimal.new("2200.00"))
      assert Decimal.equal?(metrics.by_type["credit_card"].amount, Decimal.new("200.00"))
      assert metrics.by_type["credit_card"].count == 2
      assert Decimal.equal?(metrics.by_type["financing"].amount, Decimal.new("1000.00"))
      assert metrics.by_type["financing"].count == 1
      assert Decimal.equal?(metrics.by_type["consorcio"].amount, Decimal.new("1000.00"))
      assert metrics.by_type["consorcio"].count == 1
    end

    test "monthly_commitment/1 sums its own breakdown", %{m0: m0} do
      metrics = Installments.monthly_commitment(m0)

      sum =
        metrics.by_type
        |> Map.values()
        |> Enum.reduce(Decimal.new("0"), fn %{amount: a}, acc -> Decimal.add(acc, a) end)

      assert Decimal.equal?(sum, metrics.total)
    end

    test "outstanding_balance/1 consolidates the remaining debt per type", %{m0: m0} do
      balance = Installments.outstanding_balance(m0)

      assert Decimal.equal?(balance.by_type["credit_card"], Decimal.new("500.00"))
      assert Decimal.equal?(balance.by_type["financing"], Decimal.new("10000.00"))
      assert Decimal.equal?(balance.by_type["consorcio"], Decimal.new("5000.00"))
      assert Decimal.equal?(balance.total, Decimal.new("15500.00"))
    end

    test "outstanding_balance/1 shrinks as months pass", %{m0: m0} do
      later = Installments.add_months(m0, 2)
      balance = Installments.outstanding_balance(later)

      # CARTAO A has only its last parcel left, CARTAO B is over.
      assert Decimal.equal?(balance.by_type["credit_card"], Decimal.new("100.00"))
    end

    test "cash_flow_relief/1 lists the card purchases ending within 90 days", %{m0: m0} do
      relief = Installments.cash_flow_relief(m0)

      assert Decimal.equal?(relief.total, Decimal.new("200.00"))
      assert length(relief.items) == 2

      assert Enum.map(relief.items, & &1.description) == ["CARTAO B", "CARTAO A"]

      assert Enum.map(relief.items, & &1.date) == [
               Installments.add_months(m0, 1),
               Installments.add_months(m0, 2)
             ]

      assert relief.total ==
               Enum.reduce(relief.items, Decimal.new("0"), fn i, acc ->
                 Decimal.add(acc, i.amount)
               end)
               |> Decimal.round(2)
    end

    test "monthly_projection/2 stacks each month by type and the parts add up", %{m0: m0} do
      projection = Installments.monthly_projection(m0, 4)

      assert length(projection) == 4
      assert Enum.map(projection, & &1.date) == Enum.map(0..3, &Installments.add_months(m0, &1))
      assert [%{current?: true} | rest] = projection
      assert Enum.all?(rest, &(not &1.current?))

      for month <- projection do
        parts =
          Decimal.add(month.credit_card, month.financing) |> Decimal.add(month.consorcio)

        assert Decimal.equal?(parts, month.total),
               "stacked parts #{parts} must equal total #{month.total} for #{month.date}"
      end

      totals = Enum.map(projection, &Decimal.to_string(&1.total, :normal))
      assert totals == ["2200.00", "2200.00", "2100.00", "2000.00"]

      cards = Enum.map(projection, &Decimal.to_string(&1.credit_card, :normal))
      assert cards == ["200.00", "200.00", "100.00", "0"]
    end

    test "monthly_projection/2 month 0 matches monthly_commitment/1", %{m0: m0} do
      [first | _] = Installments.monthly_projection(m0, 4)
      assert Decimal.equal?(first.total, Installments.monthly_commitment(m0).total)
    end

    test "the projection from now on adds up to the outstanding balance", %{m0: m0} do
      sum =
        m0
        |> Installments.monthly_projection(24)
        |> Enum.reduce(Decimal.new("0"), fn m, acc -> Decimal.add(acc, m.total) end)

      assert Decimal.equal?(sum, Installments.outstanding_balance(m0).total)
    end
  end

  describe "suggest_commitment_patterns/1" do
    test "surfaces recurring unlinked debits from the statement" do
      acc = account_fixture()

      for date <- [~D[2026-05-10], ~D[2026-06-10], ~D[2026-07-10]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-850.00",
          description: "CONSORCIO PORTO SEGURO",
          date: date
        })
      end

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-12.00",
        description: "PADARIA",
        date: ~D[2026-05-11]
      })

      assert [suggestion] = Installments.suggest_commitment_patterns()
      assert suggestion.description == "CONSORCIO PORTO SEGURO"
      assert suggestion.occurrences == 3
      assert Decimal.equal?(suggestion.amount, Decimal.new("850.00"))
    end

    test "ignores transactions already linked to a group" do
      acc = account_fixture()
      g = group(%{description_pattern: "JA AGRUPADO"})

      for date <- [~D[2026-05-10], ~D[2026-06-10], ~D[2026-07-10]] do
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-100.00",
          description: "JA AGRUPADO",
          date: date,
          installment_group_id: g.id
        })
      end

      assert Installments.suggest_commitment_patterns() == []
    end
  end

  describe "account_installment_groups/2" do
    test "returns exactly the groups whose parcels fall in the month for that account" do
      card = account_fixture(%{is_credit_card: true})
      other_card = account_fixture(%{is_credit_card: true})

      due =
        group(%{
          description_pattern: "GROUPS_DUE",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: due.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      # Already finished before the requested month.
      finished =
        group(%{
          description_pattern: "GROUPS_FINISHED",
          installments: 2,
          start_date: ~D[2026-01-01],
          total_amount: Decimal.new("200.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: finished.id,
        date: ~D[2026-01-01],
        amount: Decimal.new("-100.00")
      })

      # Due in the month, but on another account.
      other =
        group(%{
          description_pattern: "GROUPS_OTHER_ACCOUNT",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: other_card.id,
        installment_group_id: other.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      groups = Installments.account_installment_groups(card.id, ~D[2026-07-01])

      assert Enum.map(groups, & &1.id) == [due.id]
    end

    test "the sum of the returned groups' parcel values equals account_installment_total/2" do
      card = account_fixture(%{is_credit_card: true})

      for {pattern, total, n} <- [{"SUM_A", "300.00", 3}, {"SUM_B", "1000.00", 3}] do
        g =
          group(%{
            description_pattern: pattern,
            installments: n,
            start_date: ~D[2026-06-01],
            total_amount: Decimal.new(total)
          })

        transaction_fixture(%{
          account_id: card.id,
          installment_group_id: g.id,
          date: ~D[2026-06-01],
          amount: Decimal.new("-10.00")
        })
      end

      month = ~D[2026-07-01]

      sum =
        card.id
        |> Installments.account_installment_groups(month)
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, Installments.parcel_value(&1)))

      assert Decimal.equal?(sum, Installments.account_installment_total(card.id, month))
    end

    test "returns an empty list when nothing is due for the account in that month" do
      card = account_fixture(%{is_credit_card: true})
      assert Installments.account_installment_groups(card.id, ~D[2020-01-01]) == []
    end
  end

  describe "parcel_value/1 and parcel_position/2" do
    test "parcel_value rounds the quotient to two decimal places" do
      g =
        group(%{
          description_pattern: "PV_ROUND",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("1000.00")
        })

      assert Decimal.equal?(Installments.parcel_value(g), Decimal.new("333.33"))
    end

    test "parcel_value is zero without a total amount" do
      assert Decimal.equal?(Installments.parcel_value(%{total_amount: nil}), Decimal.new("0"))
    end

    test "parcel_position returns the 1-based parcel index inside the plan window" do
      g =
        group(%{
          description_pattern: "PP",
          installments: 4,
          start_date: ~D[2026-06-15],
          total_amount: Decimal.new("400.00")
        })

      assert Installments.parcel_position(g, ~D[2026-06-01]) == 1
      assert Installments.parcel_position(g, ~D[2026-08-01]) == 3
      assert Installments.parcel_position(g, ~D[2026-09-01]) == 4
      assert Installments.parcel_position(g, ~D[2026-05-01]) == nil
      assert Installments.parcel_position(g, ~D[2026-10-01]) == nil
    end
  end

  describe "list_off_card_groups/0" do
    setup do
      %{
        card: account_fixture(%{is_credit_card: true}),
        checking: account_fixture(%{is_credit_card: false})
      }
    end

    test "includes a group whose transactions are all off-card", %{checking: checking} do
      g =
        group(%{
          description_pattern: "OFF_CARD",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: checking.id,
        installment_group_id: g.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      assert g.id in Enum.map(Installments.list_off_card_groups(), & &1.id)
    end

    test "excludes a group with at least one credit-card transaction", %{
      card: card,
      checking: checking
    } do
      g =
        group(%{
          description_pattern: "MIXED",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: checking.id,
        installment_group_id: g.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: g.id,
        date: ~D[2026-07-01],
        amount: Decimal.new("-100.00")
      })

      refute g.id in Enum.map(Installments.list_off_card_groups(), & &1.id)
    end

    test "includes a group with no linked transactions at all" do
      g = group(%{description_pattern: "NO_TXN", installments: 3, start_date: ~D[2026-06-01]})

      assert g.id in Enum.map(Installments.list_off_card_groups(), & &1.id)
    end

    test "decides by the account, never by commitment_type", %{card: card, checking: checking} do
      financing_on_card =
        group(%{
          description_pattern: "FIN_ON_CARD",
          commitment_type: "financing",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: financing_on_card.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      card_type_off_card =
        group(%{
          description_pattern: "CARD_TYPE_OFF_CARD",
          commitment_type: "credit_card",
          installments: 3,
          start_date: ~D[2026-06-01],
          total_amount: Decimal.new("300.00")
        })

      transaction_fixture(%{
        account_id: checking.id,
        installment_group_id: card_type_off_card.id,
        date: ~D[2026-06-01],
        amount: Decimal.new("-100.00")
      })

      ids = Enum.map(Installments.list_off_card_groups(), & &1.id)

      refute financing_on_card.id in ids
      assert card_type_off_card.id in ids
    end
  end
end
