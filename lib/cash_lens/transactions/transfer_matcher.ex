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
        check_for_auto_pairing(tx)

      twin ->
        link_id = Ecto.UUID.generate()
        link_pair(tx.id, twin.id, link_id)
    end
  end

  defp check_for_auto_pairing(tx) do
    description = String.upcase(tx.description || "")

    cond do
      String.contains?(description, "BB MM OURO") ->
        create_virtual_twin(tx, "BB MM Ouro")

      String.contains?(description, ["BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
        create_virtual_twin(tx, "BB Rende Fácil")

      true ->
        :no_twin_found
    end
  end

  defp create_virtual_twin(tx, target_account_name) do
    target_account =
      Repo.one(
        from a in CashLens.Accounts.Account,
          where: ilike(a.name, ^target_account_name),
          limit: 1
      )

    if target_account do
      Logger.info(
        "Creating virtual twin for '#{tx.description}' in account '#{target_account_name}'"
      )

      link_id = Ecto.UUID.generate()

      twin_params = %{
        date: tx.date,
        description: tx.description,
        amount: Decimal.negate(tx.amount),
        account_id: target_account.id,
        category_id: tx.category_id,
        transfer_key: link_id
      }

      Repo.transaction(fn ->
        # 1. Update original by ID (avoids StaleEntryError)
        from(t in Transaction, where: t.id == ^tx.id)
        |> Repo.update_all(
          set: [
            transfer_key: link_id,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        # 2. Insert the twin (only if it doesn't exist by fingerprint)
        # Note: Twin's fingerprint will naturally be different because account_id is different
        %Transaction{}
        |> Transaction.changeset(twin_params)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :fingerprint)
      end)

      {:ok, :auto_matched}
    else
      Logger.warning("Account '#{target_account_name}' not found for auto-pairing.")
      :no_account_found
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
