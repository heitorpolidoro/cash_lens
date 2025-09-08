defmodule CashLens.TransfersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Transfers` context.
  """

  alias CashLens.AccountsFixtures
  alias CashLens.TransactionsFixtures

  @doc """
  Generate a transfer.
  """
  def transfer_fixture(attrs \\ %{}) do
    account = AccountsFixtures.account_fixture()
    from_transaction = TransactionsFixtures.transaction_fixture(%{account_id: account.id, amount: Decimal.new("-100.00")})
    to_transaction = TransactionsFixtures.transaction_fixture(%{account_id: account.id, amount: Decimal.new("100.00")})

    {:ok, transfer} =
      attrs
      |> Enum.into(%{
        from_id: from_transaction.id,
        to_id: to_transaction.id
      })
      |> CashLens.Transfers.create_transfer()

    transfer
  end
end
