defmodule CashLens.CreditCardsTest do
  use CashLens.DataCase, async: true
  alias CashLens.CreditCards
  import CashLens.CreditCardsFixtures

  test "create_statement and get_statement!" do
    s = statement_fixture()
    assert CreditCards.get_statement!(s.id).id == s.id
  end

  test "statement_status is :open without a payment" do
    s = statement_fixture(%{payment_transaction_id: nil})
    assert CreditCards.statement_status(s, Decimal.new("100.00")) == :open
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
end
