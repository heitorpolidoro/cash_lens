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
end
