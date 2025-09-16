defmodule CashLens.TransactionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transactions` context.
  """

  alias CashLens.AccountsFixtures
  alias CashLens.CategoriesFixtures
  alias CashLens.Transactions

  @doc """
  Generate a transaction.
  """
  def transaction_fixture(attrs \\ %{}) do
    account =
      (attrs[:account_id] && %{id: attrs[:account_id]}) || AccountsFixtures.account_fixture()

    category =
      (attrs[:category_id] && %{id: attrs[:category_id]}) || CategoriesFixtures.category_fixture()

    {:ok, transaction} =
      attrs
      |> Enum.into(%{
        datetime: DateTime.utc_now(),
        amount: Decimal.new("100.00"),
        reason: "some reason",
        account_id: account.id,
        category_id: category.id
      })
      |> Transactions.create_transaction()

    transaction
  end
end
