defmodule CashLens.TransactionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transactions` context.
  """

  @doc """
  Generate a transaction.
  """
  def transaction_fixture(attrs \\ %{}) do
    {:ok, transaction} =
      attrs
      |> Enum.into(%{
        amount: "120.5",
        category: "some category",
        date: ~D[2026-02-23],
        description: "some description"
      })
      |> CashLens.Transactions.create_transaction()

    transaction
  end
end
