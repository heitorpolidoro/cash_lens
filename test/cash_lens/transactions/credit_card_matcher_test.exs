defmodule CashLens.Transactions.CreditCardMatcherTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
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

  describe "match_payment/2" do
    test "links the single pending orphan batch when its sum matches" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      p1 = purchase(card, "-30.00", ~D[2026-03-01])
      p2 = purchase(card, "-70.00", ~D[2026-03-03])
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert {:ok, 2} = CreditCardMatcher.match_payment(pay)
      assert Repo.get!(Transaction, p1.id).parent_transaction_id == pay.id
      assert Repo.get!(Transaction, p2.id).parent_transaction_id == pay.id
    end

    test "returns :no_match when the single orphan batch's sum does not match" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()
      purchase(card, "-30.00", ~D[2026-03-01])
      pay = payment(checking, category, "-999.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :no_match
    end

    test "refuses auto-match when there are two distinct pending orphan batches" do
      category = credit_card_category()
      card = card_account()
      checking = checking_account()

      may_p1 = purchase(card, "-100.00", ~D[2026-04-01])
      backdate(may_p1, ~U[2026-04-02 10:00:00Z])

      jun_p1 = purchase(card, "-100.00", ~D[2026-05-01])
      backdate(jun_p1, ~U[2026-05-02 10:00:00Z])

      pay = payment(checking, category, "-100.00", ~D[2026-05-05])

      assert CreditCardMatcher.match_payment(pay) == :multiple_orphan_batches
      refute Repo.get!(Transaction, may_p1.id).parent_transaction_id
      refute Repo.get!(Transaction, jun_p1.id).parent_transaction_id
    end

    test "scopes the search to the given credit-card account hint" do
      category = credit_card_category()
      card_a = card_account()
      card_b = card_account()
      checking = checking_account()

      purchase(card_a, "-50.00", ~D[2026-03-01])
      p_b = purchase(card_b, "-50.00", ~D[2026-03-01])
      pay = payment(checking, category, "-50.00", ~D[2026-03-05])

      assert {:ok, 1} = CreditCardMatcher.match_payment(pay, card_b.id)
      assert Repo.get!(Transaction, p_b.id).parent_transaction_id == pay.id
    end

    test "returns :not_credit_card_category when the payment's category is not Cartão de Crédito" do
      checking = checking_account()
      other_category = category_fixture(%{name: "Mercado", slug: "mercado"})
      pay = payment(checking, other_category, "-100.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :not_credit_card_category
    end

    test "returns :no_match when there are no orphan batches at all" do
      category = credit_card_category()
      checking = checking_account()
      pay = payment(checking, category, "-100.00", ~D[2026-03-05])

      assert CreditCardMatcher.match_payment(pay) == :no_match
    end
  end

  defp backdate(%Transaction{id: id}, inserted_at) do
    {1, _} =
      from(t in Transaction, where: t.id == ^id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

    :ok
  end
end
