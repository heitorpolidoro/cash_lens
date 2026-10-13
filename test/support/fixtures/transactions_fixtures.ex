defmodule CashLens.TransactionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transactions` context.
  """

  alias CashLens.Tenancy

  @doc """
  Generate a transaction. Accepts `:user` to create it for an explicit owner.
  """
  def transaction_fixture(attrs \\ %{}) do
    {user, attrs} = Tenancy.pop_user(attrs)

    account_id =
      attrs[:account_id] || CashLens.AccountsFixtures.account_fixture(%{user: user}).id

    {:ok, transaction} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Enum.into(%{
          amount: "120.5",
          date: ~D[2026-02-23],
          description: "some description",
          account_id: account_id
        })
        |> CashLens.Transactions.create_transaction()
      end)

    transaction
  end

  @doc """
  Generate a transfer rule.
  """
  def transfer_rule_fixture(attrs \\ %{}) do
    {user, attrs} = Tenancy.pop_user(attrs)
    source_account = CashLens.AccountsFixtures.account_fixture(%{user: user})
    destination_account = CashLens.AccountsFixtures.account_fixture(%{user: user})
    unique_id = System.unique_integer([:positive])

    Tenancy.acting_as(user, fn ->
      {:ok, rule} =
        attrs
        |> Enum.into(%{
          label: "Rule #{unique_id}",
          description_patterns: ["pattern-#{unique_id}"],
          source_account_id: source_account.id,
          destination_account_id: destination_account.id
        })
        |> CashLens.Transactions.create_transfer_rule()

      CashLens.Transactions.get_transfer_rule!(rule.id)
    end)
  end

  @doc """
  Generate a bulk ignore pattern.
  """
  def insert_bulk_ignore_pattern(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])
    {user, attrs} = Tenancy.pop_user(attrs)

    {:ok, pattern} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Enum.into(%{
          pattern: "pattern-#{unique_id}"
        })
        |> CashLens.Transactions.create_bulk_ignore_pattern()
      end)

    pattern
  end
end
