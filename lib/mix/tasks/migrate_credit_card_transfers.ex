defmodule Mix.Tasks.MigrateCreditCardTransfers do
  @moduledoc """
  One-off data migration: converts historical transfer-linked pairs created
  by `TransferRuleApplier`'s old credit-card mirror behavior into the new
  parent/child model (spec section 5).

  Only touches a `transfer_key` pair when the payer side matches an active
  `TransferRule` (`destination_account_id` is a credit-card account,
  `create_mirror: true`) — that is the only combination guaranteed to have
  created a fictitious mirror, so it is the only case safe to delete
  automatically. Every other transfer_key pair touching a credit-card
  account is left untouched and logged for manual review.

      mix migrate_credit_card_transfers
  """
  use Mix.Task

  import Ecto.Query
  require Logger

  alias CashLens.Categories
  alias CashLens.Repo
  alias CashLens.Transactions.CreditCardMatcher
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule

  @shortdoc "Migrates historical credit-card transfer pairs to the parent/child model"

  # Coarse circuit-breaker against a runaway/misconfigured run: a personal
  # finance app realistically accumulates a handful to a few dozen
  # historical credit-card transfer pairs per year, even across several
  # years of imported history. 500 eligible pairs in one run is already
  # far beyond what any plausible real dataset would produce, so it is a
  # strong signal that `transfer_key` linking or `TransferRule` matching
  # picked up something unintended (e.g. a buggy rule mass-tagging
  # unrelated pairs). When exceeded, abort entirely rather than silently
  # deleting hundreds of "mirror" transactions unattended — better to
  # require a human to look before any destructive action happens.
  @safety_threshold 500

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Categories.get_category_by_slug("cartao-de-credito") do
      nil ->
        Logger.error(
          "MigrateCreditCardTransfers: 'cartao-de-credito' category not found — run seeds first."
        )

      category ->
        migrate(category)
    end
  end

  defp migrate(category) do
    rules = mirror_rules_by_destination()

    {migrated, ambiguous} =
      transfer_pairs()
      |> Enum.split_with(fn {payer, card_side} -> eligible?(payer, card_side, rules) end)

    if length(migrated) > @safety_threshold do
      abort_on_anomaly(migrated)
    else
      run_migration(migrated, ambiguous, category)
    end
  end

  defp abort_on_anomaly(migrated) do
    Logger.warning(
      "MigrateCreditCardTransfers: abort — #{length(migrated)} pair(s) are eligible for " <>
        "migration, which exceeds the safety threshold of #{@safety_threshold}. This is " <>
        "far more than a personal-finance dataset would realistically produce, so no " <>
        "changes were made. Review the eligible pairs manually before re-running: " <>
        inspect(Enum.map(migrated, fn {a, b} -> {a.id, b.tx.id} end))
    )
  end

  defp run_migration(migrated, ambiguous, category) do
    mirror_ids = Enum.map(migrated, fn {_payer, %{tx: mirror}} -> mirror.id end)

    Logger.info(
      "MigrateCreditCardTransfers: about to delete #{length(mirror_ids)} mirror " <>
        "transaction(s) (audit trail before destructive action): " <> inspect(mirror_ids)
    )

    Enum.each(migrated, fn {payer, card_side} -> migrate_pair(payer, card_side, category) end)

    Logger.info(
      "MigrateCreditCardTransfers: migrated #{length(migrated)} pair(s); " <>
        "#{length(ambiguous)} pair(s) left untouched for manual review: " <>
        inspect(Enum.map(ambiguous, fn {a, b} -> {a.id, b.id} end))
    )
  end

  defp mirror_rules_by_destination do
    from(r in TransferRule, where: r.create_mirror == true)
    |> Repo.all()
    |> Map.new(&{&1.destination_account_id, &1})
  end

  defp transfer_pairs do
    from(a in Transaction,
      join: b in Transaction,
      on: a.transfer_key == b.transfer_key and a.id < b.id,
      where: not is_nil(a.transfer_key),
      select: {a, b}
    )
    |> Repo.all()
    |> Enum.map(&order_by_credit_card_side/1)
  end

  defp order_by_credit_card_side({a, b}) do
    account_a = Repo.get!(CashLens.Accounts.Account, a.account_id)
    account_b = Repo.get!(CashLens.Accounts.Account, b.account_id)

    cond do
      account_b.is_credit_card -> {a, %{tx: b, account: account_b}}
      account_a.is_credit_card -> {b, %{tx: a, account: account_a}}
      true -> {a, %{tx: nil, account: nil}}
    end
  end

  defp eligible?(_payer, %{tx: nil}, _rules), do: false

  defp eligible?(payer, %{account: card_account}, rules) do
    case Map.get(rules, card_account.id) do
      %TransferRule{source_account_id: source_id} -> source_id == payer.account_id
      nil -> false
    end
  end

  defp migrate_pair(payer, %{tx: mirror, account: card_account}, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      from(t in Transaction, where: t.id == ^payer.id)
      |> Repo.update_all(set: [category_id: category.id, transfer_key: nil, updated_at: now])

      Repo.delete!(mirror)
    end)

    updated_payer = Repo.get!(Transaction, payer.id)
    CreditCardMatcher.match_payment(updated_payer, card_account.id)
  end
end
