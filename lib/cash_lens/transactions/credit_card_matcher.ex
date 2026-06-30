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
  Tries to link a freshly-imported batch of credit-card transactions to an
  existing, still-childless "Cartão de Crédito" payment transaction, by
  exact sum and date within #{@tolerance_days} days.
  """
  @spec match_batch([Transaction.t()]) ::
          {:ok, Ecto.UUID.t()} | :no_match | :ambiguous | :not_credit_card_batch
  def match_batch(transactions) when is_list(transactions) do
    case credit_card_category() do
      nil ->
        :not_credit_card_batch

      category ->
        transactions
        |> filter_credit_card_orphans()
        |> Enum.group_by(& &1.account_id)
        |> Map.values()
        |> Enum.map(&do_match_batch(&1, category))
        |> summarize_batch_results()
    end
  end

  defp summarize_batch_results([]), do: :not_credit_card_batch
  defp summarize_batch_results([result | _]), do: result

  defp do_match_batch(batch, category) do
    [%{account_id: account_id} | _] = batch
    total = Enum.reduce(batch, Decimal.new(0), &Decimal.add(&2, &1.amount))
    target_amount = total
    latest_date = batch |> Enum.map(& &1.date) |> Enum.max(Date)
    min_date = Date.add(latest_date, -@tolerance_days)
    max_date = Date.add(latest_date, @tolerance_days)

    candidates =
      candidate_payments(category, target_amount, account_id, min_date, max_date)

    case pick_unambiguous_candidate(candidates, latest_date) do
      {:ok, parent} -> link_batch(batch, parent.id)
      :tie -> :ambiguous
      :none -> :no_match
    end
  end

  defp candidate_payments(category, target_amount, exclude_account_id, min_date, max_date) do
    from(t in Transaction,
      where: t.category_id == ^category.id,
      where: t.amount == ^target_amount,
      where: t.account_id != ^exclude_account_id,
      where: t.date >= ^min_date and t.date <= ^max_date,
      where: t.id not in subquery(linked_parent_ids_query())
    )
    |> Repo.all()
  end

  # IDs of every transaction that already has at least one child — used to
  # exclude payments that already have a (possibly different) batch linked.
  defp linked_parent_ids_query do
    from(c in Transaction,
      where: not is_nil(c.parent_transaction_id),
      distinct: true,
      select: c.parent_transaction_id
    )
  end

  defp pick_unambiguous_candidate([], _latest_date), do: :none

  defp pick_unambiguous_candidate(candidates, latest_date) do
    [{best_diff, best} | rest] =
      candidates
      |> Enum.map(&{abs(Date.diff(&1.date, latest_date)), &1})
      |> Enum.sort_by(&elem(&1, 0))

    if Enum.any?(rest, fn {diff, _} -> diff == best_diff end) do
      :tie
    else
      {:ok, best}
    end
  end

  defp link_batch(batch, parent_id) do
    ids = Enum.map(batch, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Transaction, where: t.id in ^ids)
    |> Repo.update_all(set: [parent_transaction_id: parent_id, updated_at: now])

    {:ok, parent_id}
  end

  defp filter_credit_card_orphans(transactions) do
    account_ids = transactions |> Enum.map(& &1.account_id) |> Enum.uniq()
    credit_card_ids = MapSet.new(credit_card_account_ids(account_ids))

    Enum.filter(transactions, fn t ->
      MapSet.member?(credit_card_ids, t.account_id) and is_nil(t.parent_transaction_id)
    end)
  end

  defp credit_card_account_ids(account_ids) do
    from(a in Account, where: a.id in ^account_ids and a.is_credit_card == true, select: a.id)
    |> Repo.all()
  end

  defp credit_card_category, do: Categories.get_category_by_slug("cartao-de-credito")
end
