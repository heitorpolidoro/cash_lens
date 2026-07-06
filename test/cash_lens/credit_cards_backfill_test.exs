defmodule CashLens.CreditCardsBackfillTest do
  use CashLens.DataCase, async: true

  test "backfill_file stamps existing rows by fingerprint without touching category" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    cat = CashLens.CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})

    existing =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("10.00"),
        description: "UBER",
        date: ~D[2026-06-02],
        category_id: cat.id
      })

    parsed = [%{description: "UBER", amount: Decimal.new("10.00"), date: ~D[2026-06-02]}]

    meta = %{
      due_date: ~D[2026-06-15],
      total_a_pagar: Decimal.new("10.00"),
      competencia: ~D[2026-06-01]
    }

    {:ok, statement} = CashLens.CreditCards.backfill_file(card, parsed, meta, "fatura.pdf")

    reloaded = CashLens.Repo.get!(CashLens.Transactions.Transaction, existing.id)
    assert reloaded.import_batch_id == statement.id
    assert reloaded.category_id == cat.id
  end

  test "backfill_file does not create duplicate transactions" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

    _existing =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("25.00"),
        description: "MERCADO",
        date: ~D[2026-06-03]
      })

    before_count =
      CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count)

    parsed = [%{description: "MERCADO", amount: Decimal.new("25.00"), date: ~D[2026-06-03]}]

    meta = %{
      due_date: ~D[2026-06-15],
      total_a_pagar: Decimal.new("25.00"),
      competencia: ~D[2026-06-01]
    }

    {:ok, _statement} = CashLens.CreditCards.backfill_file(card, parsed, meta, "fatura2.pdf")

    after_count =
      CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count)

    assert before_count == after_count
  end

  test "backfill_file stamps two identical rows with distinct fingerprints in one file" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

    t0 =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("5.00"),
        description: "PADARIA",
        date: ~D[2026-06-04]
      })

    t1 =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: card.id,
        amount: Decimal.new("5.00"),
        description: "PADARIA",
        date: ~D[2026-06-04],
        occurrence_index: 1
      })

    parsed = [
      %{description: "PADARIA", amount: Decimal.new("5.00"), date: ~D[2026-06-04]},
      %{description: "PADARIA", amount: Decimal.new("5.00"), date: ~D[2026-06-04]}
    ]

    meta = %{due_date: nil, total_a_pagar: nil, competencia: nil}

    {:ok, statement} = CashLens.CreditCards.backfill_file(card, parsed, meta, "fatura3.pdf")

    r0 = CashLens.Repo.get!(CashLens.Transactions.Transaction, t0.id)
    r1 = CashLens.Repo.get!(CashLens.Transactions.Transaction, t1.id)

    assert r0.import_batch_id == statement.id
    assert r1.import_batch_id == statement.id
  end
end
