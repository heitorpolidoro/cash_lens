defmodule CashLens.TransactionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transactions` context.
  """

  @doc """
  Generate a category.
  """
  def category_fixture(attrs \\ %{}) do
    {:ok, category} =
      attrs
      |> Enum.into(%{
        name: "some category",
        type: "some type"
      })
      |> CashLens.Transactions.create_category()

    category
  end

  @doc """
  Generate a transaction.
  """
  def transaction_fixture(attrs \\ %{}) do
    category = attrs[:category] || category_fixture()

    {:ok, transaction} =
      attrs
      |> Enum.into(%{
        date: ~D[2024-06-01],
        time: ~T[12:00:00],
        reason: "some reason",
        category_id: category.id,
        amount: "120.5"
      })
      |> CashLens.Transactions.create_transaction()

    transaction
  end
end
