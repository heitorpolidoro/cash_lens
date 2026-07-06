defmodule CashLens.CreditCards.MatcherTest do
  use CashLens.DataCase, async: true
  import CashLens.CreditCardsFixtures
  alias CashLens.CreditCards.Matcher

  setup do
    CashLens.CategoriesFixtures.category_fixture(%{
      name: "Cartão de Crédito",
      slug: "cartao-de-credito"
    })

    :ok
  end

  test "auto_link links the single exact-amount payment within the window" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})
    cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

    s =
      statement_fixture(%{
        account: card,
        total_a_pagar: Decimal.new("30.00"),
        due_date: ~D[2026-06-15]
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      amount: Decimal.new("30.00"),
      import_batch_id: s.id,
      date: ~D[2026-06-05]
    })

    payment =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: bank.id,
        amount: Decimal.new("30.00"),
        category_id: cat.id,
        date: ~D[2026-06-16]
      })

    assert {:linked, linked} = Matcher.auto_link(s, Decimal.new("30.00"))
    assert linked.id == payment.id
    assert CashLens.CreditCards.get_statement!(s.id).payment_transaction_id == payment.id
  end

  test "auto_link returns :no_match when no candidate amount matches" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("99.00")})
    assert Matcher.auto_link(s, Decimal.new("99.00")) == :no_match
  end
end
