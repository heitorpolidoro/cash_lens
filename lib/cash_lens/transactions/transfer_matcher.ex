defmodule CashLens.Transactions.TransferMatcher do
  @moduledoc """
  Logic to automatically link transfers between different accounts.
  """
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Categories

  @doc """
  Tries to find a matching pair for a given transaction if it's a transfer.
  """
  def match_transfer(%Transaction{category_id: nil}), do: :no_match
  def match_transfer(%Transaction{transfer_key: key}) when not is_nil(key), do: :already_matched

  def match_transfer(%Transaction{} = tx) do
    # Only try to match if the category is "transfer"
    case Categories.get_category!(tx.category_id) do
      %{slug: "transfer"} -> find_and_link(tx)
      _ -> :not_a_transfer
    end
  end

  defp find_and_link(tx) do
    target_amount = Decimal.negate(tx.amount)

    # Search for a twin transaction: same date, opposite amount, different account, no key yet
    query = from t in Transaction,
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
        
        # Link both transactions with the same key
        Repo.transaction(fn ->
          tx |> Ecto.Changeset.change(transfer_key: link_id) |> Repo.update!()
          twin |> Ecto.Changeset.change(transfer_key: link_id) |> Repo.update!()
        end)
        
        {:ok, link_id}
    end
  end
end
