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
    case rules_and_category() do
      nil ->
        []

      {rules_by_source, transfer_category} ->
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
    case rules_and_category() do
      nil ->
        []

      {rules_by_source, transfer_category} ->
        apply_rules_to_transaction(transaction, rules_by_source, transfer_category)
    end
  end

  # Returns {rules_by_source, transfer_category} when both transfer rules and the
  # "transfer" category exist; otherwise nil so callers can short-circuit.
  defp rules_and_category do
    case load_rules_by_source() do
      rules when rules == %{} ->
        nil

      rules ->
        case get_transfer_category() do
          nil -> nil
          category -> {rules, category}
        end
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
    link_id = Ecto.UUID.generate()
    mirror_id = Ecto.UUID.generate()

    mirror_params = %{
      id: mirror_id,
      date: tx.date,
      description: tx.description,
      amount: mirror_amount,
      account_id: rule.destination_account_id,
      category_id: transfer_category.id,
      transfer_key: link_id
    }

    changeset = Transaction.changeset(%Transaction{}, mirror_params)

    case repo_mod().insert(changeset,
           on_conflict: {:replace, [:updated_at]},
           conflict_target: :fingerprint,
           returning: true
         ) do
      {:ok, mirror} ->
        link_mirror(tx, mirror, link_id, mirror.id == mirror_id)

      {:error, reason} ->
        Logger.warning(
          "TransferRuleApplier: Failed to insert mirror transaction: #{inspect(reason)}"
        )

        []
    end
  end

  # Links the mirror to its source transaction. A mirror that already carries a
  # different transfer_key was linked elsewhere, so it is left untouched. Only a
  # freshly inserted mirror is returned to the caller.
  defp link_mirror(tx, mirror, link_id, is_new) do
    if is_nil(mirror.transfer_key) || mirror.transfer_key == link_id do
      link_pair(tx.id, mirror.id, link_id)
      if is_new, do: [%{mirror | transfer_key: link_id}], else: []
    else
      []
    end
  end

  defp repo_mod, do: Application.get_env(:cash_lens, :transfer_rule_repo, CashLens.Repo)

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
