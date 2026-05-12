defmodule CashLens.Transactions.TransferRuleApplier do
  @moduledoc """
  Applies transfer rules to transactions, creating mirrored transactions in destination accounts.
  """
  require Logger
  import Ecto.Query

  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  @doc """
  Applies transfer rules to a list of transactions (batch variant for import pipeline).

  For each transaction that matches a rule, creates a mirrored transaction in the destination
  account (if one does not already exist) and sets both transactions' category to "transfer".

  Returns the list of newly created mirror transactions.
  """
  def apply_rules(transactions) when is_list(transactions) do
    transfer_category = get_transfer_category()

    if is_nil(transfer_category) do
      []
    else
      rules_by_source = load_rules_by_source()

      Enum.flat_map(transactions, fn tx ->
        apply_rules_to_transaction(tx, rules_by_source, transfer_category)
      end)
    end
  end

  @doc """
  Applies transfer rules to a single transaction (single-transaction variant).

  Returns a list of newly created mirror transactions (0 or 1 elements).
  """
  def maybe_apply_rule(%Transaction{} = transaction) do
    transfer_category = get_transfer_category()

    if is_nil(transfer_category) do
      []
    else
      rules_by_source = load_rules_by_source()
      apply_rules_to_transaction(transaction, rules_by_source, transfer_category)
    end
  end

  defp load_rules_by_source do
    TransferRule
    |> Repo.all()
    |> Enum.group_by(& &1.source_account_id)
  end

  defp get_transfer_category do
    case Categories.get_category_by_slug("transfer") do
      nil ->
        Logger.warning(
          "TransferRuleApplier: 'transfer' category not found; skipping rule application."
        )

        nil

      category ->
        category
    end
  end

  defp apply_rules_to_transaction(tx, rules_by_source, transfer_category) do
    account_rules = Map.get(rules_by_source, tx.account_id, [])
    description_lower = String.downcase(tx.description || "")

    matched_rule =
      Enum.find(account_rules, fn rule ->
        Enum.any?(rule.description_patterns, fn pattern ->
          String.downcase(pattern) == description_lower
        end)
      end)

    if matched_rule do
      set_transfer_category(tx, transfer_category)
      maybe_create_mirror(tx, matched_rule, transfer_category)
    else
      []
    end
  end

  defp set_transfer_category(tx, transfer_category) do
    if tx.category_id != transfer_category.id do
      from(t in Transaction, where: t.id == ^tx.id)
      |> Repo.update_all(
        set: [
          category_id: transfer_category.id,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
    end
  end

  defp maybe_create_mirror(tx, rule, transfer_category) do
    mirror_amount = Decimal.negate(tx.amount)

    existing =
      Repo.one(
        from t in Transaction,
          where:
            t.account_id == ^rule.destination_account_id and
              t.date == ^tx.date and
              t.description == ^tx.description and
              t.amount == ^mirror_amount,
          limit: 1
      )

    if existing do
      if is_nil(existing.transfer_key) do
        link_id = Ecto.UUID.generate()
        link_pair(tx.id, existing.id, link_id)
      end

      []
    else
      link_id = Ecto.UUID.generate()

      mirror_params = %{
        date: tx.date,
        description: tx.description,
        amount: mirror_amount,
        account_id: rule.destination_account_id,
        category_id: transfer_category.id,
        transfer_key: link_id
      }

      changeset = Transaction.changeset(%Transaction{}, mirror_params)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :fingerprint) do
        {:ok, mirror} ->
          link_pair(tx.id, mirror.id, link_id)
          [mirror]

        {:error, reason} ->
          Logger.warning(
            "TransferRuleApplier: Failed to insert mirror transaction: #{inspect(reason)}"
          )

          []
      end
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
