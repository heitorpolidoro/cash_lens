defmodule CashLens.Transactions.CreditCardMatcherTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction

  defp credit_card_category,
    do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

  defp card_account, do: account_fixture(%{is_credit_card: true})
  defp checking_account, do: account_fixture(%{is_credit_card: false})

  defp purchase(account, amount, date) do
    transaction_fixture(%{
      account_id: account.id,
      amount: amount,
      date: date,
      description: "compra"
    })
  end

  defp payment(account, category, amount, date) do
    transaction_fixture(%{
      account_id: account.id,
      category_id: category.id,
      amount: amount,
      date: date,
      description: "pagamento fatura"
    })
  end

  describe "match_batch/1" do
    test "links the batch to a payment when the sum and date match" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()

      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      p2 = purchase(card, "-70.00", ~D[2026-03-03])
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert {:ok, parent_id} = CreditCardMatcher.match_batch([p1, p2])
      assert parent_id == pay.id

      assert Repo.get!(Transaction, p1.id).parent_transaction_id == pay.id
      assert Repo.get!(Transaction, p2.id).parent_transaction_id == pay.id
    end

    test "returns :no_match when no payment has the matching amount" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      payment(checking, category, "-999.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_batch([p1]) == :no_match
    end

    test "returns :no_match when the matching payment is outside the date tolerance" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      payment(checking, category, "-30.00", ~D[2026-03-20])

      assert CreditCardMatcher.match_batch([p1]) == :no_match
    end

    test "returns :ambiguous and links nothing when two candidates tie on date diff" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-05])
      pay_a = payment(checking, category, "-30.00", ~D[2026-03-03])
      pay_b = payment(checking, category, "-30.00", ~D[2026-03-07])

      assert CreditCardMatcher.match_batch([p1]) == :ambiguous
      assert Repo.get!(Transaction, p1.id).parent_transaction_id == nil
      assert Repo.get!(Transaction, pay_a.id).parent_transaction_id == nil
      assert Repo.get!(Transaction, pay_b.id).parent_transaction_id == nil
    end

    test "nets out a refund mixed with purchases" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-100.00", ~D[2026-03-01])
      refund = purchase(card, "20.00", ~D[2026-03-02])
      pay = payment(checking, category, "-80.00", ~D[2026-03-05])

      assert {:ok, parent_id} = CreditCardMatcher.match_batch([p1, refund])
      assert parent_id == pay.id
    end

    test "returns :not_credit_card_batch when no transaction is from a credit-card account" do
      checking = checking_account()
      p1 = purchase(checking, "-30.00", ~D[2026-03-01])

      assert CreditCardMatcher.match_batch([p1]) == :not_credit_card_batch
    end

    test "returns :not_credit_card_batch when the category does not exist" do
      card = card_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])

      assert CreditCardMatcher.match_batch([p1]) == :not_credit_card_batch
    end

    test "ignores transactions that already have a parent" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      pay = payment(checking, category, "-30.00", ~D[2026-03-05])
      p1 = purchase(card, "-30.00", ~D[2026-03-01])

      {1, _} =
        from(t in Transaction, where: t.id == ^p1.id)
        |> Repo.update_all(set: [parent_transaction_id: pay.id])

      reloaded = Repo.get!(Transaction, p1.id)
      assert CreditCardMatcher.match_batch([reloaded]) == :not_credit_card_batch
    end
  end
end
