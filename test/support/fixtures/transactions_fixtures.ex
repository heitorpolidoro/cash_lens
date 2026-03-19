defmodule CashLens.TransactionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transactions` context.
  """

  @doc """
  Generate a transaction.
  """
  def transaction_fixture(attrs \\ %{}) do
    account_id = attrs[:account_id] || CashLens.AccountsFixtures.account_fixture().id

    {:ok, transaction} =
      attrs
      |> Enum.into(%{
        amount: "120.5",
        date: ~D[2026-02-23],
        description: "some description",
        account_id: account_id
      })
      |> CashLens.Transactions.create_transaction()

    transaction
  end
end
