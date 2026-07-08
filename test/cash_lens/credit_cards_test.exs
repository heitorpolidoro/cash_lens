defmodule CashLens.CreditCardsTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards
  import Ecto.Query
  import CashLens.CreditCardsFixtures

  test "create_statement and get_statement!" do
    s = statement_fixture()
    assert CreditCards.get_statement!(s.id).id == s.id
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
end
