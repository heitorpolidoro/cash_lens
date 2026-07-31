defmodule CashLens.CreditCardsTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards
  import Ecto.Query
  import CashLens.CreditCardsFixtures

  test "create_statement and get_statement!" do
    s = statement_fixture()
    assert CreditCards.get_statement!(s.id).id == s.id
  end

  test "get_statement_by_account_and_competencia/2 tolerates duplicate rows for the same account+competencia, returning the most recent" do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    competencia = ~D[2026-06-01]

    {:ok, older} =
      CreditCards.create_statement(%{
        account_id: account.id,
        competencia: competencia,
        due_date: ~D[2026-06-15],
        total_a_pagar: Decimal.new("100.00"),
        source_file: "fatura1.pdf"
      })

    # Force a distinct, later inserted_at so ordering is deterministic
    older
    |> Ecto.Changeset.change(inserted_at: DateTime.add(older.inserted_at, -60, :second))
    |> CashLens.Repo.update!()

    {:ok, newer} =
      CreditCards.create_statement(%{
        account_id: account.id,
        competencia: competencia,
        due_date: ~D[2026-06-15],
        total_a_pagar: Decimal.new("200.00"),
        source_file: "fatura2.pdf"
      })

    result = CreditCards.get_statement_by_account_and_competencia(account.id, competencia)

    assert result.id == newer.id
  end

  test "statement_status is :open without a payment" do
    s = statement_fixture(%{payment_transaction_id: nil})
    assert CreditCards.statement_status(s, Decimal.new("100.00")) == :open
  end

  describe "statement_status pending/absorbed" do
    test ":absorbed when absorbed_by is set (highest priority)" do
      s = %CashLens.CreditCards.Statement{
        absorbed_by_statement_id: Ecto.UUID.generate(),
        due_date: nil
      }

      assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :absorbed
    end

    test ":pending when no Vencimento, no payment, not absorbed" do
      s = %CashLens.CreditCards.Statement{
        due_date: nil,
        payment_transaction_id: nil,
        absorbed_by_statement_id: nil
      }

      assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :pending
    end

    test ":open still applies to an unpaid boleto (has Vencimento)" do
      s = %CashLens.CreditCards.Statement{
        due_date: ~D[2026-03-10],
        payment_transaction_id: nil,
        absorbed_by_statement_id: nil
      }

      assert CashLens.CreditCards.statement_status(s, Decimal.new("0")) == :open
    end
  end

  describe "competencia_from/2" do
    test "keeps the parsed due-date competência when present" do
      txns = [%{date: ~D[2026-05-20]}]
      assert CreditCards.competencia_from(~D[2026-06-01], txns) == ~D[2026-06-01]
    end

    test "falls back to the latest transaction's month when competência is nil" do
      txns = [%{date: ~D[2026-05-03]}, %{date: ~D[2026-05-28]}, %{date: ~D[2026-04-11]}]
      assert CreditCards.competencia_from(nil, txns) == ~D[2026-05-01]
    end

    test "is nil when there is no competência and no dated transaction" do
      assert CreditCards.competencia_from(nil, []) == nil
    end
  end

  describe "competencia_for/3" do
    @cycle %{closing_day: 3, due_day: 10}

    test "boleto uses the parsed competência (due month)" do
      meta = %{due_date: ~D[2026-03-10], total_a_pagar: nil, competencia: ~D[2026-03-01]}
      assert CashLens.CreditCards.competencia_for(@cycle, meta, []) == ~D[2026-03-01]
    end

    test "non-boleto with cycle: latest tx 27/01, closing 3, due 10 -> Fev/26" do
      meta = %{due_date: nil, total_a_pagar: nil, competencia: nil}
      txns = [%{date: ~D[2026-01-12]}, %{date: ~D[2026-01-27]}]
      assert CashLens.CreditCards.competencia_for(@cycle, meta, txns) == ~D[2026-02-01]
    end

    test "non-boleto, tx before closing_day stays in the same closing month" do
      meta = %{due_date: nil, competencia: nil}

      # closing 25, due 10 (due <= closing -> due next month). tx 20/06 -> closing 25/06 -> due 10/07
      cycle = %{closing_day: 25, due_day: 10}

      assert CashLens.CreditCards.competencia_for(cycle, meta, [%{date: ~D[2026-06-20]}]) ==
               ~D[2026-07-01]
    end

    test "non-boleto without cycle falls back to transaction month" do
      meta = %{due_date: nil, competencia: nil}
      cycle = %{closing_day: nil, due_day: nil}

      assert CashLens.CreditCards.competencia_for(cycle, meta, [%{date: ~D[2026-01-27]}]) ==
               ~D[2026-01-01]
    end

    test "non-boleto with cycle but no transactions -> nil" do
      assert CashLens.CreditCards.competencia_for(@cycle, %{due_date: nil, competencia: nil}, []) ==
               nil
    end
  end

  test "list_statements returns rows with line totals and status" do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: account, total_a_pagar: Decimal.new("30.00")})

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: account.id,
      amount: Decimal.new("10.00"),
      import_batch_id: s.id
    })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: account.id,
      amount: Decimal.new("20.00"),
      import_batch_id: s.id
    })

    [row] = CashLens.CreditCards.list_statements()
    assert row.statement.id == s.id
    assert Decimal.equal?(row.line_total, Decimal.new("30.00"))
    assert row.line_count == 2
    assert row.status == :open
    assert row.absorbed_into == nil
  end

  test "list_statements orders by competência descending (nulls last)" do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    older = statement_fixture(%{account: account, competencia: ~D[2026-01-01]})
    newer = statement_fixture(%{account: account, competencia: ~D[2026-03-01]})
    no_comp = statement_fixture(%{account: account, competencia: nil, due_date: nil})

    ids = CashLens.CreditCards.list_statements() |> Enum.map(& &1.statement.id)
    assert ids == [newer.id, older.id, no_comp.id]
  end

  test "get_statement_detail returns transactions and payment" do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: account})

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: account.id,
      amount: Decimal.new("5.00"),
      import_batch_id: s.id
    })

    detail = CashLens.CreditCards.get_statement_detail(s.id)
    assert length(detail.transactions) == 1
    assert detail.payment == nil
  end

  test "link_payment sets statement payment and children parents" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("30.00")})

    child =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("30.00"),
        import_batch_id: s.id
      })

    payment =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: bank.id,
        amount: Decimal.new("30.00")
      })

    {:ok, s2} = CashLens.CreditCards.link_payment(s, payment.id)
    assert s2.payment_transaction_id == payment.id

    assert CashLens.Repo.get!(CashLens.Transactions.Transaction, child.id).parent_transaction_id ==
             payment.id

    {:ok, s3} = CashLens.CreditCards.unlink_payment(s2)
    assert s3.payment_transaction_id == nil

    assert CashLens.Repo.get!(CashLens.Transactions.Transaction, child.id).parent_transaction_id ==
             nil
  end

  test "link_payment also parents transactions of absorbed statements" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})

    boleto =
      statement_fixture(%{account: card, total_a_pagar: Decimal.new("56.53")})

    # Create absorbed statement with unique source_file to avoid collisions
    absorbed =
      statement_fixture(%{
        account: card,
        due_date: nil,
        total_a_pagar: Decimal.new("3.40"),
        absorbed_by_statement_id: boleto.id,
        source_file: "absorbed-#{Ecto.UUID.generate()}.pdf"
      })

    boleto_tx =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        import_batch_id: boleto.id,
        amount: "50.00",
        date: ~D[2026-02-20],
        description: "boleto tx"
      })

    absorbed_tx =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        import_batch_id: absorbed.id,
        amount: "60.00",
        date: ~D[2026-02-21],
        description: "absorbed tx"
      })

    payment = CashLens.TransactionsFixtures.transaction_fixture(%{account_id: bank.id})

    {:ok, _} = CashLens.CreditCards.link_payment(boleto, payment.id)

    reload = fn id ->
      CashLens.Repo.get!(CashLens.Transactions.Transaction, id).parent_transaction_id
    end

    assert reload.(boleto_tx.id) == payment.id
    assert reload.(absorbed_tx.id) == payment.id

    {:ok, _} = CashLens.CreditCards.unlink_payment(boleto)
    assert reload.(boleto_tx.id) == nil
    assert reload.(absorbed_tx.id) == nil
  end

  test "suggest_payment returns best matching payment" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})

    # Create the cartao-de-credito category
    {:ok, category} =
      CashLens.Categories.create_category(%{
        name: "Cartão de Crédito",
        slug: "cartao-de-credito"
      })

    # Create statement
    today = Date.utc_today()
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("100.00"), due_date: today})

    # Create multiple payments to choose from
    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: bank.id,
      amount: Decimal.new("50.00"),
      category_id: category.id,
      parent_transaction_id: nil
    })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: bank.id,
      amount: Decimal.new("100.00"),
      category_id: category.id,
      date: today,
      parent_transaction_id: nil
    })

    # Create a linked payment that should be excluded
    linked_payment =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: bank.id,
        amount: Decimal.new("100.00"),
        category_id: category.id
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: bank.id,
      amount: Decimal.new("100.00"),
      category_id: category.id,
      parent_transaction_id: linked_payment.id
    })

    best = CashLens.CreditCards.suggest_payment(s)
    assert best.amount == Decimal.new("100.00")
    assert best.date == today
  end

  test "suggest_payment returns nil when no category exists" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card})

    assert CashLens.CreditCards.suggest_payment(s) == nil
  end

  test "reset_account_statements deletes the account's transactions and statements" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    other = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card})

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      import_batch_id: s.id
    })

    keep = statement_fixture(%{account: other})

    {stmts, txns} = CashLens.CreditCards.reset_account_statements(card.id)
    assert stmts == 1
    assert txns == 1

    assert CashLens.Repo.aggregate(
             from(t in CashLens.Transactions.Transaction, where: t.account_id == ^card.id),
             :count
           ) == 0

    # other account untouched
    assert CashLens.CreditCards.get_statement!(keep.id).id == keep.id
  end

  describe "absorb_pending/1" do
    setup do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      %{card: card}
    end

    test "absorbs an earlier pending when total - |items| equals its total", %{card: card} do
      # Pending Feb: total_a_pagar 3.40 (its line items are irrelevant to the formula)
      pending =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: nil,
          competencia: ~D[2026-01-01],
          total_a_pagar: Decimal.new("3.40")
        })

      # Boleto March: total 56.53, line items summing to -53.13 -> 56.53 - 53.13 = 3.40
      boleto =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-03-10],
          competencia: ~D[2026-03-01],
          total_a_pagar: Decimal.new("56.53")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("-53.13"),
        import_batch_id: boleto.id,
        date: ~D[2026-02-20]
      })

      assert [absorbed] = CashLens.CreditCards.absorb_pending(boleto)
      assert absorbed.id == pending.id
      assert CashLens.CreditCards.get_statement!(pending.id).absorbed_by_statement_id == boleto.id
    end

    test "does not absorb when the sum is off by a cent", %{card: card} do
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: nil,
        competencia: ~D[2026-01-01],
        total_a_pagar: Decimal.new("3.41")
      })

      boleto =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-03-10],
          competencia: ~D[2026-03-01],
          total_a_pagar: Decimal.new("56.53")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("-53.13"),
        import_batch_id: boleto.id
      })

      assert CashLens.CreditCards.absorb_pending(boleto) == []
    end

    test "ignores pending that are not earlier than the boleto", %{card: card} do
      # competencia == boleto's (not strictly earlier) -> not eligible
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: nil,
        competencia: ~D[2026-03-01],
        total_a_pagar: Decimal.new("0.00")
      })

      boleto =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          due_date: ~D[2026-03-10],
          competencia: ~D[2026-03-01],
          total_a_pagar: Decimal.new("53.13")
        })

      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("-53.13"),
        import_batch_id: boleto.id
      })

      assert CashLens.CreditCards.absorb_pending(boleto) == []
    end
  end

  test "reconcile_pending absorbs existing pending and propagates an existing payment" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})

    pending =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: nil,
        competencia: ~D[2026-01-01],
        total_a_pagar: Decimal.new("3.40")
      })

    pending_tx =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("-3.40"),
        import_batch_id: pending.id
      })

    payment = CashLens.TransactionsFixtures.transaction_fixture(%{account_id: bank.id})

    boleto =
      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: ~D[2026-03-10],
        competencia: ~D[2026-03-01],
        total_a_pagar: Decimal.new("56.53"),
        payment_transaction_id: payment.id
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      amount: Decimal.new("-53.13"),
      import_batch_id: boleto.id
    })

    assert CashLens.CreditCards.reconcile_pending() == 1
    assert CashLens.CreditCards.get_statement!(pending.id).absorbed_by_statement_id == boleto.id
    # payment propagated to the absorbed statement's transaction
    assert CashLens.Repo.get!(CashLens.Transactions.Transaction, pending_tx.id).parent_transaction_id ==
             payment.id

    # idempotent
    assert CashLens.CreditCards.reconcile_pending() == 0
  end

  test "recompute_competencia fixes a non-boleto's competência from the cycle" do
    card =
      CashLens.AccountsFixtures.account_fixture(%{
        is_credit_card: true,
        closing_day: 3,
        due_day: 10
      })

    s =
      statement_fixture(%{
        account: card,
        due_date: nil,
        competencia: ~D[2026-01-01],
        total_a_pagar: Decimal.new("50.00")
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      amount: Decimal.new("-50.00"),
      import_batch_id: s.id,
      date: ~D[2026-01-27]
    })

    assert CashLens.CreditCards.recompute_competencia() == 1
    assert CashLens.CreditCards.get_statement!(s.id).competencia == ~D[2026-02-01]
    # idempotent
    assert CashLens.CreditCards.recompute_competencia() == 0
  end

  describe "estimate_cycle/1" do
    test "estimates due_day as the modal boleto due day and closing 7 days earlier" do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      statement_fixture(%{account: card, due_date: ~D[2026-01-10]})
      statement_fixture(%{account: card, due_date: ~D[2026-02-10]})
      statement_fixture(%{account: card, due_date: ~D[2026-03-15]})

      assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: 3, due_day: 10}
    end

    test "wraps closing_day when due_day <= 7" do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      statement_fixture(%{account: card, due_date: ~D[2026-01-05]})
      assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: 28, due_day: 5}
    end

    test "nils when the account has no boletos" do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      assert CashLens.CreditCards.estimate_cycle(card) == %{closing_day: nil, due_day: nil}
    end
  end
end
