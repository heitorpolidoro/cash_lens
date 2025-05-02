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
        date: ~D[2024-06-01],
        time: ~T[12:00:00],
        reason: "some reason",
        category: "some category",
        amount: "120.5"
      })
      |> CashLens.Transactions.create_transaction()

    transaction
  end
end
