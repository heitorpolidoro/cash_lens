defmodule CashLens.CreditCardsTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards
  alias CashLens.CreditCards.Statement
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

  test "suggest_payment does not offer a payment already reconciled elsewhere" do
    # This test used to assert the opposite: that the top-ranked candidate was
    # returned even when it was already some statement's payment. That is the
    # defect that put an 11.938,58 Ourocard payment under "Pagamento Detectado"
    # on a 1.357,95 Mercado Pago bill.
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})

    {:ok, category} =
      CashLens.Categories.create_category(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

    today = Date.utc_today()
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("100.00"), due_date: today})

    paid =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: bank.id,
        amount: Decimal.new("-100.00"),
        category_id: category.id,
        date: today,
        parent_transaction_id: nil
      })

    # The auto-matcher claims it on sight, which is the correct outcome.
    assert CashLens.Repo.get!(Statement, s.id).payment_transaction_id == paid.id

    other =
      statement_fixture(%{
        account: CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true}),
        total_a_pagar: Decimal.new("100.00"),
        due_date: today
      })

    assert CashLens.CreditCards.suggest_payment(other) == nil
  end

  test "suggest_payment returns nil when no category exists" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card})

    assert CashLens.CreditCards.suggest_payment(s) == nil
  end

  describe "payment matching with real-world signs" do
    # A card payment leaves the current account, so its stored amount is
    # NEGATIVE while `total_a_pagar` is positive. Comparing the two unsigned
    # made `|amount - total|` equal `|amount| + total`, which ranks by the
    # SMALLEST payment rather than the closest one.
    #
    # Note that `CashLens.CreditCards.Matcher` auto-links an exact-amount
    # payment inside its own 15-day window the moment either side is created,
    # so a test that wants an exact payment to stay *unlinked* has to avoid
    # that path -- hence the near-miss amounts below.
    setup do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      bank = CashLens.AccountsFixtures.account_fixture(%{})

      {:ok, category} =
        CashLens.Categories.create_category(%{
          name: "Cartão de Crédito",
          slug: "cartao-de-credito"
        })

      %{card: card, bank: bank, category: category, today: Date.utc_today()}
    end

    # The description varies because two otherwise-identical rows are rejected
    # as duplicates at insert, so an "ambiguous" pair cannot be built without it.
    defp payment(bank, category, amount, date, description \\ nil) do
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: bank.id,
        amount: Decimal.new(amount),
        category_id: category.id,
        date: date,
        description: description || "Pagto cartao #{System.unique_integer([:positive])}",
        parent_transaction_id: nil
      })
    end

    test "ranks by magnitude, so the nearest payment wins over a smaller one", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("11938.58"),
          due_date: ctx.today
        })

      _small = payment(ctx.bank, ctx.category, "-100.00", ctx.today)
      near = payment(ctx.bank, ctx.category, "-11900.00", ctx.today)

      assert [first | _] = CashLens.CreditCards.payment_candidates(statement)

      # Under the old unsigned comparison the -100,00 payment won, because
      # |amount| + total is monotonic in |amount|.
      assert first.id == near.id
    end

    test "a payment reconciled to another statement is not offered here", ctx do
      other_card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

      other =
        statement_fixture(%{
          account: other_card,
          total_a_pagar: Decimal.new("11938.58"),
          due_date: ctx.today
        })

      # Auto-linked to `other` on creation; this is the real-world shape of the
      # defect -- the Ourocard payment being offered to the Mercado Pago bill.
      taken = payment(ctx.bank, ctx.category, "-11938.58", ctx.today)
      assert CashLens.Repo.get!(Statement, other.id).payment_transaction_id == taken.id

      mine =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      ids = mine |> CashLens.CreditCards.payment_candidates() |> Enum.map(& &1.id)

      refute taken.id in ids
      assert CashLens.CreditCards.suggest_payment(mine) == nil
    end

    test "no suggestion when the amount does not match the total", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      payment(ctx.bank, ctx.category, "-11938.58", ctx.today)

      # Still listed for manual linking -- just not announced as detected.
      assert length(CashLens.CreditCards.payment_candidates(statement)) == 1
      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "suggests one of two identical payments the auto-matcher refused as ambiguous", ctx do
      a = payment(ctx.bank, ctx.category, "-500.00", ctx.today, "Pagto cartao A")
      b = payment(ctx.bank, ctx.category, "-500.00", ctx.today, "Pagto cartao B")

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("500.00"),
          due_date: ctx.today
        })

      # Both payments must exist BEFORE the statement: created afterwards, the
      # first one auto-links on its own and there is never any ambiguity.
      assert CashLens.Repo.get!(Statement, statement.id).payment_transaction_id == nil

      suggestion = CashLens.CreditCards.suggest_payment(statement)
      assert suggestion.id in [a.id, b.id]
    end

    test "a late payment above the total is suggested after the due date", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      # Fine and interest push a late payment ABOVE the bill.
      late = payment(ctx.bank, ctx.category, "-1047.30", Date.add(ctx.today, 5))

      assert CashLens.CreditCards.suggest_payment(statement).id == late.id
    end

    test "the same amount BEFORE the due date is not a late payment", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      payment(ctx.bank, ctx.category, "-1047.30", Date.add(ctx.today, -5))

      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "a payment BELOW the total is never suggested, late or not", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      # A partial payment is not a settlement.
      payment(ctx.bank, ctx.category, "-900.00", Date.add(ctx.today, 5))

      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "a late payment more than 20% over the total is not suggested", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      at_ceiling = payment(ctx.bank, ctx.category, "-1200.00", Date.add(ctx.today, 5))
      assert CashLens.CreditCards.suggest_payment(statement).id == at_ceiling.id

      {:ok, _} =
        CashLens.Transactions.delete_transaction(
          CashLens.Transactions.get_transaction!(at_ceiling.id)
        )

      payment(ctx.bank, ctx.category, "-1200.01", Date.add(ctx.today, 5))
      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "a late payment beyond 30 days is not suggested", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      payment(ctx.bank, ctx.category, "-1050.00", Date.add(ctx.today, 31))

      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "an exact match wins over a late one even when the late one is nearer in date", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1000.00"),
          due_date: ctx.today
        })

      _late = payment(ctx.bank, ctx.category, "-1050.00", Date.add(ctx.today, 1))
      exact = payment(ctx.bank, ctx.category, "-1000.00", Date.add(ctx.today, 8))

      # The exact payment is auto-linked on sight, which is the strongest
      # possible outcome -- the statement needs no suggestion at all.
      assert CashLens.Repo.get!(Statement, statement.id).payment_transaction_id == exact.id
    end

    test "unlinked_card_payments reads the whole cartao-de-credito subtree", ctx do
      {:ok, child} =
        CashLens.Categories.create_category(%{
          name: "Ourocard",
          slug: "cartao-de-credito-ourocard",
          parent_id: ctx.category.id
        })

      # payment_candidates no longer filters by category at all, so the subtree
      # only still matters here.
      in_child = payment(ctx.bank, child, "-800.00", ctx.today, "Pagto Ourocard")

      ids = Enum.map(CashLens.CreditCards.unlinked_card_payments(), & &1.id)
      assert in_child.id in ids
    end

    test "a credit sitting on a card account is never a candidate", ctx do
      other_card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("500.00"),
          due_date: ctx.today
        })

      # The card side of a payment: positive, and on a credit-card account.
      # Money leaving for a bill never comes from another card.
      #
      # The amount deliberately does NOT equal the total: an exact one would be
      # auto-linked on creation and then excluded as "already reconciled",
      # which would make this test pass without the account filter doing
      # anything at all.
      payment(other_card, ctx.category, "499.00", ctx.today)

      assert CashLens.CreditCards.payment_candidates(statement) == []
      assert CashLens.CreditCards.suggest_payment(statement) == nil
    end

    test "a payment with an unrelated category is still a candidate", ctx do
      {:ok, outros} = CashLens.Categories.create_category(%{name: "Outros", slug: "outros"})

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      # The real case: a Pix paying the bill, filed as "Outros". Filtering by
      # category is what hid it.
      pix =
        payment(ctx.bank, outros, "-1357.95", ctx.today, "Pix - Enviado - MERCADO PAGO")

      ids = statement |> CashLens.CreditCards.payment_candidates() |> Enum.map(& &1.id)
      assert pix.id in ids
    end

    test "a credit is never a candidate, whatever its category", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("500.00"),
          due_date: ctx.today
        })

      payment(ctx.bank, ctx.category, "499.00", ctx.today)

      assert CashLens.CreditCards.payment_candidates(statement) == []
    end

    test "candidates outside the due-date window are not listed", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("500.00"),
          due_date: ctx.today
        })

      inside = payment(ctx.bank, ctx.category, "-480.00", Date.add(ctx.today, -45))
      _early = payment(ctx.bank, ctx.category, "-470.00", Date.add(ctx.today, -46))
      _late = payment(ctx.bank, ctx.category, "-460.00", Date.add(ctx.today, 31))

      ids = statement |> CashLens.CreditCards.payment_candidates() |> Enum.map(& &1.id)
      assert ids == [inside.id]
    end

    test "linking files the payment under Cartão de Crédito", ctx do
      {:ok, outros} = CashLens.Categories.create_category(%{name: "Outros", slug: "outros"})

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      pix = payment(ctx.bank, outros, "-1300.00", ctx.today, "Pix - Enviado")
      assert pix.category_id == outros.id

      {:ok, _} = CashLens.CreditCards.link_payment(statement, pix.id)

      assert CashLens.Transactions.get_transaction!(pix.id).category_id == ctx.category.id
    end

    test "linking leaves a more specific card subcategory alone", ctx do
      {:ok, child} =
        CashLens.Categories.create_category(%{
          name: "Ourocard",
          slug: "cartao-de-credito-ourocard",
          parent_id: ctx.category.id
        })

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("900.00"),
          due_date: ctx.today
        })

      already = payment(ctx.bank, child, "-880.00", ctx.today)

      {:ok, _} = CashLens.CreditCards.link_payment(statement, already.id)

      # The operator's own, narrower choice is not overwritten by the parent.
      assert CashLens.Transactions.get_transaction!(already.id).category_id == child.id
    end

    test "an internal transfer is not a candidate", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      # Money moving between the operator's own accounts. The amount is
      # deliberately NOT the statement total: an exact one is auto-linked on
      # creation and then excluded as "already reconciled", which would make
      # this test pass with the transfer guard removed.
      transfer =
        payment(ctx.bank, ctx.category, "-1300.00", ctx.today, "Transferencia interna")

      {:ok, _} =
        CashLens.Transactions.update_transaction(transfer, %{
          transfer_key: Ecto.UUID.generate()
        })

      ids = statement |> CashLens.CreditCards.payment_candidates() |> Enum.map(& &1.id)
      refute transfer.id in ids
    end

    test "unlinked_card_payments lists what no statement claims", ctx do
      {:ok, outros} = CashLens.Categories.create_category(%{name: "Outros", slug: "outros"})

      loose = payment(ctx.bank, ctx.category, "-321.00", ctx.today, "Pagto solto")
      _other_category = payment(ctx.bank, outros, "-99.00", ctx.today, "Nao e cartao")

      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("777.00"),
          due_date: ctx.today
        })

      claimed = payment(ctx.bank, ctx.category, "-777.00", ctx.today, "Pagto da fatura")
      assert CashLens.Repo.get!(Statement, statement.id).payment_transaction_id == claimed.id

      ids = Enum.map(CashLens.CreditCards.unlinked_card_payments(), & &1.id)

      assert loose.id in ids
      refute claimed.id in ids
    end

    test "a credit that is a line of some statement is not unlinked", ctx do
      statement =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("1357.95"),
          due_date: ctx.today
        })

      # "Pagamento da fatura de junho/2026": the receipt for the previous bill,
      # printed as a line of the next one. It belongs to that cycle.
      receipt = payment(ctx.card, ctx.category, "1412.10", ctx.today, "Pagamento da fatura")

      {:ok, _} =
        CashLens.Transactions.update_transaction(receipt, %{import_batch_id: statement.id})

      ids = Enum.map(CashLens.CreditCards.unlinked_card_payments(), & &1.id)
      refute receipt.id in ids
    end

    test "a card credit belonging to no statement is still surfaced", ctx do
      stray = payment(ctx.card, ctx.category, "1412.10", ctx.today, "Credito orfao")

      ids = Enum.map(CashLens.CreditCards.unlinked_card_payments(), & &1.id)
      assert stray.id in ids
    end

    test "unlinked_card_payments ignores transactions outside the category", ctx do
      {:ok, outros} = CashLens.Categories.create_category(%{name: "Outros", slug: "outros"})
      not_card = payment(ctx.bank, outros, "-50.00", ctx.today, "Mercado")

      ids = Enum.map(CashLens.CreditCards.unlinked_card_payments(), & &1.id)

      refute not_card.id in ids
    end

    test "no suggestion without a total or without a due date", ctx do
      payment(ctx.bank, ctx.category, "-500.00", ctx.today)

      no_total = statement_fixture(%{account: ctx.card, total_a_pagar: nil, due_date: ctx.today})

      no_due =
        statement_fixture(%{
          account: ctx.card,
          total_a_pagar: Decimal.new("500.00"),
          due_date: nil
        })

      assert CashLens.CreditCards.suggest_payment(no_total) == nil
      assert CashLens.CreditCards.suggest_payment(no_due) == nil
    end
  end

  describe "closed_without_statement/2" do
    import CashLens.AccountsFixtures
    import CashLens.CreditCardsFixtures

    defp card(attrs) do
      account_fixture(Map.merge(%{is_credit_card: true}, attrs))
    end

    test "reports a cycle whose closing day has passed with no statement" do
      # Closes on the 3rd, due on the 10th: the cycle closing 03/10 is the
      # October competência.
      account = card(%{name: "AMAZON", closing_day: 3, due_day: 10})

      assert [gap] = CreditCards.closed_without_statement(~D[2026-10-06], 1)
      assert gap.account.id == account.id
      assert gap.competencia == ~D[2026-10-01]
      assert gap.closed_on == ~D[2026-10-03]
    end

    test "says nothing while the cycle is still open" do
      # Closes on the 12th; on the 6th that has not happened yet, so the newest
      # closed cycle is September's.
      account = card(%{name: "CARTAO", closing_day: 12, due_day: 17})

      statement_fixture(%{
        account: account,
        competencia: ~D[2026-09-01],
        due_date: ~D[2026-09-17]
      })

      assert CreditCards.closed_without_statement(~D[2026-10-06], 1) == []
    end

    test "says nothing once the statement is on record" do
      account = card(%{name: "AMEX", closing_day: 6, due_day: 16})

      statement_fixture(%{
        account: account,
        competencia: ~D[2026-10-01],
        due_date: ~D[2026-10-16]
      })

      assert CreditCards.closed_without_statement(~D[2026-10-06], 1) == []
    end

    test "places the competência in the next month when closing follows the due day" do
      # Closes on the 25th, due on the 5th: the cycle closing 25/09 is due in
      # October, so its competência is October.
      card(%{name: "TARDIO", closing_day: 25, due_day: 5})

      assert [gap] = CreditCards.closed_without_statement(~D[2026-10-06], 1)
      assert gap.competencia == ~D[2026-10-01]
      assert gap.closed_on == ~D[2026-09-25]
    end

    test "looks back over several cycles, newest first" do
      card(%{name: "ATRASADO", closing_day: 3, due_day: 10})

      gaps = CreditCards.closed_without_statement(~D[2026-10-06], 3)

      assert Enum.map(gaps, & &1.competencia) == [~D[2026-10-01], ~D[2026-09-01], ~D[2026-08-01]]
    end

    test "skips cards with no cycle configured and closed cards" do
      card(%{name: "SEM CICLO", closing_day: nil, due_day: nil})
      card(%{name: "ENCERRADO", closing_day: 3, due_day: 10, is_closed: true})

      assert CreditCards.closed_without_statement(~D[2026-10-06], 3) == []
    end
  end
end
