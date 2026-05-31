defmodule CashLens.Transactions.TransferMatcher do
  @moduledoc """
  Logic to automatically link transfers between different accounts.
  """
  require Logger
  import Ecto.Query
  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  @doc """
  Tries to find matching pairs for given transactions if they are transfers.
  Can receive a single transaction or a list.
  """
  def match_transfers(transactions) when is_list(transactions) do
    # 1. Filter out already matched or invalid
    transfers =
      transactions
      |> Enum.filter(fn
        %Transaction{id: id, category_id: cat_id, transfer_key: nil}
        when not is_nil(id) and not is_nil(cat_id) ->
          true

        _ ->
          false
      end)

    # 2. Match only those with 'transfer' category
    # Pre-fetch 'transfer' category slug for efficiency
    transfer_category = Categories.get_category_by_slug("transfer")

    if transfer_category do
      transfers
      |> Enum.filter(&(&1.category_id == transfer_category.id))
      |> Enum.each(&find_and_link/1)
    end
  end

  def match_transfer(%Transaction{id: nil}), do: :no_match
  def match_transfer(%Transaction{category_id: nil}), do: :no_match
  def match_transfer(%Transaction{transfer_key: key}) when not is_nil(key), do: :already_matched

  def match_transfer(%Transaction{} = tx) do
    # Only try to match if the category is "transfer"
    case Categories.get_category_by_slug("transfer") do
      %{id: id} when tx.category_id == id -> find_and_link(tx)
      _ -> :not_a_transfer
    end
  end

  defp find_and_link(tx) do
    target_amount = Decimal.negate(tx.amount)

    # Search for a twin transaction: same date, opposite amount, different account, no key yet
    query =
      from t in Transaction,
        where: t.id != ^tx.id,
        where: t.account_id != ^tx.account_id,
        where: t.date == ^tx.date,
        where: t.amount == ^target_amount,
        where: is_nil(t.transfer_key),
        limit: 1

    case Repo.one(query) do
      nil ->
        :no_twin_found

      twin ->
        link_id = Ecto.UUID.generate()
        link_pair(tx.id, twin.id, link_id)
    end
  end

  defp link_pair(tx_id, twin_id, link_id) do
    Repo.transaction(fn ->
      from(t in Transaction, where: t.id in [^tx_id, ^twin_id])
      |> Repo.update_all(
        set: [transfer_key: link_id, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
    end)

    {:ok, link_id}
  end
end
