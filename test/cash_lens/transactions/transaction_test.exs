defmodule CashLens.Transactions.TransactionTest do
  use CashLens.DataCase, async: true

  alias CashLens.Transactions.Transaction

  test "decode_account_id" do
    assert Ecto.UUID.cast!(Ecto.UUID.generate()) |> is_binary()

    invalid_binary = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>

    changeset =
      Transaction.changeset(%Transaction{}, %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: invalid_binary
      })

    assert Ecto.UUID.cast!(changeset.changes.account_id)
  end
end
