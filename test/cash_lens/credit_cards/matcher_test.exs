defmodule CashLens.CreditCards.MatcherTest do
  use CashLens.DataCase, async: true
  import CashLens.CreditCardsFixtures
  import Ecto.Query
  alias CashLens.CreditCards.Matcher
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  # Sets the category via Repo.update_all/2 (bypassing create_transaction/1's
  # eager CreditCardMatcher hook) so these tests can exercise match_payment/2
  # directly, in isolation from the now-automatic matching that happens on
  # transaction creation/category updates.
  defp payment(account, category, amount, date) do
    tx =
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: account.id,
        amount: amount,
        date: date,
        description: "pagamento fatura"
      })

    {1, _} =
      from(t in Transaction, where: t.id == ^tx.id)
      |> Repo.update_all(set: [category_id: category.id])

    %{tx | category_id: category.id}
  end

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

    pay = payment(bank, cat, Decimal.new("30.00"), ~D[2026-06-16])

    assert {:linked, linked} = Matcher.auto_link(s, Decimal.new("30.00"))
    assert linked.id == pay.id
    assert CashLens.CreditCards.get_statement!(s.id).payment_transaction_id == pay.id
  end

  test "auto_link matches a payment categorized under a descendant category" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})
    parent = CashLens.Categories.get_category_by_slug("cartao-de-credito")

    child =
      CashLens.CategoriesFixtures.category_fixture(%{
        name: "Amex",
        slug: "cartao-de-credito-amex",
        parent_id: parent.id
      })

    s =
      statement_fixture(%{
        account: card,
        total_a_pagar: Decimal.new("1099.28"),
        due_date: ~D[2026-05-10]
      })

    CashLens.TransactionsFixtures.transaction_fixture(%{
      account_id: card.id,
      amount: Decimal.new("-1099.28"),
      import_batch_id: s.id,
      date: ~D[2026-05-01]
    })

    # Bank-side debit filed under the per-card CHILD category, as the user does.
    pay = payment(bank, child, Decimal.new("-1099.28"), ~D[2026-05-11])

    assert {:linked, linked} = Matcher.auto_link(s, Decimal.new("-1099.28"))
    assert linked.id == pay.id
    assert CashLens.CreditCards.get_statement!(s.id).payment_transaction_id == pay.id
  end

  test "auto_link returns :no_match when no candidate amount matches" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    s = statement_fixture(%{account: card, total_a_pagar: Decimal.new("99.00")})
    assert Matcher.auto_link(s, Decimal.new("99.00")) == :no_match
  end

  test "auto_link returns :ambiguous and does not link when two candidates match" do
    card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
    bank = CashLens.AccountsFixtures.account_fixture(%{})
    cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

    s =
      statement_fixture(%{
        account: card,
        total_a_pagar: Decimal.new("30.00"),
        due_date: ~D[2026-06-15]
      })

    _pay1 = payment(bank, cat, Decimal.new("30.00"), ~D[2026-06-16])
    _pay2 = payment(bank, cat, Decimal.new("30.00"), ~D[2026-06-17])

    assert Matcher.auto_link(s, Decimal.new("30.00")) == :ambiguous
    assert CashLens.CreditCards.get_statement!(s.id).payment_transaction_id == nil
  end

  describe "match_payment/2" do
    test "links the payment to the single open statement whose total matches within the window" do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      bank = CashLens.AccountsFixtures.account_fixture(%{})
      cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      statement =
        statement_fixture(%{
          account: card,
          total_a_pagar: Decimal.new("30.00"),
          due_date: ~D[2026-06-15]
        })

      child =
        CashLens.TransactionsFixtures.transaction_fixture(%{
          account_id: card.id,
          amount: Decimal.new("30.00"),
          import_batch_id: statement.id,
          date: ~D[2026-06-05]
        })

      pay = payment(bank, cat, Decimal.new("-30.00"), ~D[2026-06-16])

      assert {:linked, linked} = Matcher.match_payment(pay)
      assert linked.id == statement.id
      assert CashLens.CreditCards.get_statement!(statement.id).payment_transaction_id == pay.id
      assert Repo.get!(Transaction, child.id).parent_transaction_id == pay.id
    end

    test "returns :no_match when no open statement's total matches the payment" do
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      bank = CashLens.AccountsFixtures.account_fixture(%{})
      cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      statement_fixture(%{account: card, total_a_pagar: Decimal.new("99.00")})

      pay = payment(bank, cat, Decimal.new("-30.00"), ~D[2026-06-16])

      assert Matcher.match_payment(pay) == :no_match
    end

    test "returns :not_credit_card_category when the payment's category is not Cartão de Crédito" do
      bank = CashLens.AccountsFixtures.account_fixture(%{})

      other_category =
        CashLens.CategoriesFixtures.category_fixture(%{name: "Mercado", slug: "mercado"})

      pay = payment(bank, other_category, Decimal.new("-30.00"), ~D[2026-06-16])

      assert Matcher.match_payment(pay) == :not_credit_card_category
    end

    test "credit_card_account_id scopes matching to a single card account" do
      card_a = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      card_b = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      bank = CashLens.AccountsFixtures.account_fixture(%{})
      cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      statement_a =
        statement_fixture(%{
          account: card_a,
          total_a_pagar: Decimal.new("30.00"),
          due_date: ~D[2026-06-15]
        })

      statement_b =
        statement_fixture(%{
          account: card_b,
          total_a_pagar: Decimal.new("30.00"),
          due_date: ~D[2026-06-15]
        })

      pay = payment(bank, cat, Decimal.new("-30.00"), ~D[2026-06-16])

      assert {:linked, linked} = Matcher.match_payment(pay, card_a.id)
      assert linked.id == statement_a.id

      assert CashLens.CreditCards.get_statement!(statement_a.id).payment_transaction_id ==
               pay.id

      assert CashLens.CreditCards.get_statement!(statement_b.id).payment_transaction_id == nil
    end

    test "returns :no_match and leaves other open statements untouched when the payment is already linked" do
      card_a = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      card_b = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})
      bank = CashLens.AccountsFixtures.account_fixture(%{})
      cat = CashLens.Categories.get_category_by_slug("cartao-de-credito")

      statement_a =
        statement_fixture(%{
          account: card_a,
          total_a_pagar: Decimal.new("30.00"),
          due_date: ~D[2026-06-15]
        })

      statement_b =
        statement_fixture(%{
          account: card_b,
          total_a_pagar: Decimal.new("30.00"),
          due_date: ~D[2026-06-15]
        })

      pay = payment(bank, cat, Decimal.new("-30.00"), ~D[2026-06-16])

      assert {:linked, _linked} = Matcher.match_payment(pay, card_a.id)
      linked_pay = Repo.get!(Transaction, pay.id)

      assert Matcher.match_payment(linked_pay) == :no_match

      assert CashLens.CreditCards.get_statement!(statement_a.id).payment_transaction_id ==
               pay.id

      assert CashLens.CreditCards.get_statement!(statement_b.id).payment_transaction_id == nil
    end
  end
end
