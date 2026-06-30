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
