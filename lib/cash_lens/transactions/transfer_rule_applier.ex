defmodule CashLens.Transactions.TransferRuleApplier do
  @moduledoc """
  Applies transfer rules to transactions, creating mirrored transactions in destination accounts.
  """
  require Logger
  import Ecto.Query

  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  @doc """
  Applies transfer rules to a list of transactions (batch variant for import pipeline).

  For each transaction that matches a rule, creates a mirrored transaction in the destination
  account (if one does not already exist) and sets both transactions' category to "transfer".

  Returns the list of newly created mirror transactions.
  """
  def apply_rules(transactions) when is_list(transactions) do
    case load_rules_by_source() do
      rules when rules == %{} ->
        []

      rules_by_source ->
        Enum.flat_map(transactions, fn tx ->
          apply_rules_to_transaction(tx, rules_by_source)
        end)
    end
  end

  @doc """
  Applies transfer rules to a single transaction (single-transaction variant).

  Returns a list of newly created mirror transactions (0 or 1 elements).
  """
  def maybe_apply_rule(%Transaction{} = transaction) do
    case load_rules_by_source() do
      rules when rules == %{} ->
        []

      rules_by_source ->
        apply_rules_to_transaction(transaction, rules_by_source)
    end
  end

  defp load_rules_by_source do
    TransferRule
    |> Repo.all()
    |> Repo.preload(:destination_account)
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

  defp apply_rules_to_transaction(tx, rules_by_source) do
    account_rules = Map.get(rules_by_source, tx.account_id, [])
    description_lower = String.downcase(tx.description || "")

    matched_rule =
      Enum.find(account_rules, fn rule ->
        Enum.any?(rule.description_patterns, fn pattern ->
          String.contains?(description_lower, String.downcase(pattern))
        end)
      end)

    case matched_rule do
      nil -> []
      rule -> apply_matched_rule(tx, rule)
    end
  end

  defp apply_matched_rule(tx, %{destination_account: %{is_credit_card: true}} = rule) do
    apply_credit_card_rule(tx, rule)
  end

  defp apply_matched_rule(tx, rule) do
    case get_transfer_category() do
      nil ->
        []

      transfer_category ->
        set_category(tx, transfer_category)

        if rule.create_mirror do
          maybe_create_mirror(tx, rule, transfer_category)
        else
          []
        end
    end
  end

  defp apply_credit_card_rule(tx, rule) do
    case Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        Logger.warning(
          "TransferRuleApplier: 'cartao-de-credito' category not found; skipping rule application."
        )

        []

      category ->
        set_category(tx, category)

        CreditCardMatcher.match_payment(
          %{tx | category_id: category.id},
          rule.destination_account_id
        )

        []
    end
  end

  defp set_category(tx, category) do
    if tx.category_id != category.id do
      from(t in Transaction, where: t.id == ^tx.id)
      |> Repo.update_all(
        set: [
          category_id: category.id,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
    end
  end

  defp maybe_create_mirror(tx, rule, transfer_category) do
    mirror_amount = Decimal.negate(tx.amount)
    link_id = Ecto.UUID.generate()
    mirror_id = Ecto.UUID.generate()

    # The mirror uses the default occurrence index (0). Re-running the rule for
    # the same source must reproduce the same mirror fingerprint so the
    # `on_conflict: {:replace, [:updated_at]}` upsert stays idempotent (no second
    # mirror). A would-be second mirror for an identical twin source therefore
    # upserts onto the existing one rather than creating a duplicate — matching
    # the pre-occurrence-index behavior.
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
    transfer_cat = Categories.get_category_by_slug("transfer")
    cat_id = transfer_cat && transfer_cat.id

    Repo.transaction(fn ->
      from(t in Transaction, where: t.id in [^tx_id, ^twin_id])
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
