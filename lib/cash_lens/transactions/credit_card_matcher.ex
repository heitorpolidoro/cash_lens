defmodule CashLens.Transactions.CreditCardMatcher do
  @moduledoc """
  Links credit-card invoice line items (children) to their bill-payment
  transaction (parent). Mirrors `TransferMatcher`, but matches the SUM of
  N children against 1 parent instead of a strict 1:1 pair.
  """
  import Ecto.Query

  alias CashLens.Accounts.Account
  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  @tolerance_days 5

  @doc """
  Tries to link a transaction that was just categorized as "Cartão de
  Crédito" to its corresponding orphan batch of credit-card purchases.

  `credit_card_account_id` narrows the search to one card account when the
  caller knows it (e.g. a `TransferRule`'s destination); pass `nil` to
  search across every credit-card account.
  """
  @spec match_payment(Transaction.t(), Ecto.UUID.t() | nil) ::
          {:ok, non_neg_integer()}
          | :no_match
          | :multiple_orphan_batches
          | :not_credit_card_category
  def match_payment(%Transaction{} = payment, credit_card_account_id \\ nil) do
    case credit_card_category() do
      nil ->
        :not_credit_card_category

      %{id: category_id} when payment.category_id != category_id ->
        :not_credit_card_category

      _category ->
        account_ids =
          if credit_card_account_id,
            do: [credit_card_account_id],
            else: all_credit_card_account_ids()

        account_ids
        |> orphan_batches()
        |> do_match_payment(payment)
    end
  end

  defp do_match_payment([], _payment), do: :no_match

  defp do_match_payment([batch], payment) do
    if batch_matches_payment?(batch, payment) do
      link_batch_and_count(batch, payment)
    else
      :no_match
    end
  end

  defp do_match_payment(_batches, _payment), do: :multiple_orphan_batches

  defp batch_matches_payment?(batch, payment) do
    total = Enum.reduce(batch, Decimal.new(0), &Decimal.add(&2, &1.amount))
    latest_date = batch |> Enum.map(& &1.date) |> Enum.max(Date)

    Decimal.equal?(total, payment.amount) and
      abs(Date.diff(latest_date, payment.date)) <= @tolerance_days
  end

  defp link_batch_and_count(batch, payment) do
    ids = Enum.map(batch, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(t in Transaction, where: t.id in ^ids)
      |> Repo.update_all(set: [parent_transaction_id: payment.id, updated_at: now])

    {:ok, count}
  end

  defp orphan_batches(account_ids) do
    from(t in Transaction,
      where: t.account_id in ^account_ids,
      where: is_nil(t.parent_transaction_id)
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.account_id, &1.inserted_at})
    |> Map.values()
  end

  defp all_credit_card_account_ids do
    from(a in Account, where: a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end

  defp credit_card_category, do: Categories.get_category_by_slug("cartao-de-credito")
end
