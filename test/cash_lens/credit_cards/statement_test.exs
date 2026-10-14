defmodule CashLens.CreditCards.StatementTest do
  use CashLens.DataCase, async: true

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.CreditCards.Statement

  test "changeset requires account_id" do
    changeset = Statement.changeset(%Statement{}, %{})
    refute changeset.valid?
    assert %{account_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset accepts full attrs for the owner's own account and payment" do
    %{a: a} = cross_tenant()
    account = account_fixture(%{user: a})
    payment = transaction_fixture(%{user: a})

    attrs = %{
      account_id: account.id,
      competencia: ~D[2026-06-01],
      due_date: ~D[2026-06-15],
      total_a_pagar: Decimal.new("3812.40"),
      source_file: "ourocard_2026-06.pdf",
      payment_transaction_id: payment.id
    }

    assert Statement.changeset(%Statement{user_id: a.id}, attrs).valid?
  end

  test "changeset rejects an account, payment or absorbing statement owned by someone else" do
    %{a: a, b: b} = cross_tenant()
    account = account_fixture(%{user: a})
    payment = transaction_fixture(%{user: a})
    other = CashLens.CreditCardsFixtures.statement_fixture(%{user: a})

    changeset =
      Statement.changeset(%Statement{user_id: b.id}, %{
        account_id: account.id,
        payment_transaction_id: payment.id,
        absorbed_by_statement_id: other.id
      })

    refute changeset.valid?

    assert %{
             account_id: ["does not exist"],
             payment_transaction_id: ["does not exist"],
             absorbed_by_statement_id: ["does not exist"]
           } = errors_on(changeset)
  end
end
