defmodule CashLens.Transactions.TransferMatcher do
  @moduledoc """
  Logic to automatically link transfers between different accounts.

  Every function names the user the transactions belong to; only that user's
  transactions and categories take part, and a transaction owned by someone
  else is never matched or linked.
  """
  require Logger
  import Ecto.Query
  alias CashLens.Categories
  alias CashLens.Ownership
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Users.User

  @doc """
  Tries to find matching pairs for given transactions if they are transfers.
  Receives a list of transactions.
  """
  def match_transfers(%User{} = user, transactions) when is_list(transactions) do
    # 1. Filter out already matched, invalid or foreign transactions
    transfers =
      transactions
      |> Enum.filter(fn
        %Transaction{id: id, category_id: cat_id, transfer_key: nil, user_id: owner_id}
        when not is_nil(id) and not is_nil(cat_id) and owner_id == user.id ->
          true

        _ ->
          false
      end)

    # 2. Match only those with 'transfer' category
    # Pre-fetch 'transfer' category slug for efficiency
    transfer_category = Categories.get_category_by_slug(user, "transfer")

    if transfer_category do
      transfers
      |> Enum.filter(&(&1.category_id == transfer_category.id))
      |> Enum.reduce(MapSet.new(), &collect_linked_accounts(user, &1, &2))
      |> MapSet.to_list()
    else
      nil
    end
  end

  defp collect_linked_accounts(user, tx, acc) do
    case find_and_link(user, tx) do
      {:ok, twin_account_id} ->
        acc
        |> MapSet.put(tx.account_id)
        |> MapSet.put(twin_account_id)

      _ ->
        acc
    end
  end

  def match_transfer(%User{}, %Transaction{id: nil}), do: :no_match
  def match_transfer(%User{}, %Transaction{category_id: nil}), do: :no_match

  def match_transfer(%User{}, %Transaction{transfer_key: key}) when not is_nil(key),
    do: :already_matched

  def match_transfer(%User{id: user_id}, %Transaction{user_id: owner_id})
      when owner_id != user_id,
      do: :no_match

  def match_transfer(%User{} = user, %Transaction{} = tx) do
    # Only try to match if the category is "transfer"
    case Categories.get_category_by_slug(user, "transfer") do
      %{id: id} when tx.category_id == id -> find_and_link(user, tx)
      _ -> :not_a_transfer
    end
  end

  defp find_and_link(user, tx) do
    target_amount = Decimal.negate(tx.amount)

    # Search for a twin transaction: same date, opposite amount, different account, no key yet,
    # and either uncategorized or already categorized as transfer.
    query =
      from t in Ownership.scope(Transaction, user),
        where: t.id != ^tx.id,
        where: t.account_id != ^tx.account_id,
        where: t.date == ^tx.date,
        where: t.amount == ^target_amount,
        where: is_nil(t.transfer_key),
        where: is_nil(t.category_id) or t.category_id == ^tx.category_id,
        limit: 1

    case Repo.one(query) do
      nil ->
        :no_twin_found

      twin ->
        link_id = Ecto.UUID.generate()
        link_pair(user, tx.id, twin.id, link_id)
        {:ok, twin.account_id}
    end
  end

  defp link_pair(user, tx_id, twin_id, link_id) do
    transfer_cat = Categories.get_category_by_slug(user, "transfer")
    cat_id = transfer_cat && transfer_cat.id

    Repo.transaction(fn ->
      from(t in Ownership.scope(Transaction, user), where: t.id in [^tx_id, ^twin_id])
      |> Repo.update_all(
        set: [
          transfer_key: link_id,
          category_id: cat_id,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
    end)

    {:ok, link_id}
  end
end
