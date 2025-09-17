# TODO Review
defmodule CashLens.TransfersTest do
  use CashLens.DataCase

  alias CashLens.Transfers

  describe "transfers" do
    alias CashLens.Transfers.Transfer

    import CashLens.TransfersFixtures
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    @invalid_attrs %{account_id: nil, from_id: nil, to_id: nil}

    test "list_transfers/0 returns all transfers" do
      transfer = transfer_fixture()
      assert [retrieved_transfer] = Transfers.list_transfers()
      assert retrieved_transfer.id == transfer.id
    end

    test "list_transfers_by_account/1 returns transfers for a specific account" do
      transfer = transfer_fixture()
      assert [retrieved_transfer] = Transfers.list_transfers_by_account(transfer.account_id)
      assert retrieved_transfer.id == transfer.id

      # Create another account and verify no transfers are returned for it
      other_account = account_fixture()
      assert Transfers.list_transfers_by_account(other_account.id) == []
    end

    test "get_transfer!/1 returns the transfer with given id" do
      transfer = transfer_fixture()
      retrieved_transfer = Transfers.get_transfer!(transfer.id)
      assert retrieved_transfer.id == transfer.id
    end

    test "create_transfer/1 with valid data creates a transfer" do
      account = account_fixture()

      from_transaction =
        transaction_fixture(%{account_id: account.id, amount: Decimal.new("-100.00")})

      to_transaction =
        transaction_fixture(%{account_id: account.id, amount: Decimal.new("100.00")})

      valid_attrs = %{
        from_id: from_transaction.id,
        to_id: to_transaction.id
      }

      assert {:ok, %Transfer{} = transfer} = Transfers.create_transfer(valid_attrs)
      assert transfer.account_id == account.id
      assert transfer.from_id == from_transaction.id
      assert transfer.to_id == to_transaction.id
    end

    test "create_transfer/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Transfers.create_transfer(@invalid_attrs)
    end

    test "create_transfer/1 with same from and to transactions returns error changeset" do
      account = account_fixture()
      transaction = transaction_fixture(%{account_id: account.id})

      invalid_attrs = %{
        account_id: account.id,
        from_id: transaction.id,
        to_id: transaction.id
      }

      assert {:error, %Ecto.Changeset{}} = Transfers.create_transfer(invalid_attrs)
    end

    test "update_transfer/2 with valid data updates the transfer" do
      transfer = transfer_fixture()
      account = account_fixture()

      from_transaction =
        transaction_fixture(%{account_id: account.id, amount: Decimal.new("-200.00")})

      to_transaction =
        transaction_fixture(%{account_id: account.id, amount: Decimal.new("200.00")})

      update_attrs = %{
        from_id: from_transaction.id,
        to_id: to_transaction.id
      }

      assert {:ok, %Transfer{} = updated_transfer} =
               Transfers.update_transfer(transfer, update_attrs)

      assert updated_transfer.account_id == account.id
      assert updated_transfer.from_id == from_transaction.id
      assert updated_transfer.to_id == to_transaction.id
    end

    test "update_transfer/2 with invalid data returns error changeset" do
      transfer = transfer_fixture()
      assert {:error, %Ecto.Changeset{}} = Transfers.update_transfer(transfer, @invalid_attrs)
      retrieved_transfer = Transfers.get_transfer!(transfer.id)
      assert retrieved_transfer.id == transfer.id
    end

    test "delete_transfer/1 deletes the transfer" do
      transfer = transfer_fixture()
      assert {:ok, %Transfer{}} = Transfers.delete_transfer(transfer)
      assert_raise Ecto.NoResultsError, fn -> Transfers.get_transfer!(transfer.id) end
    end

    test "change_transfer/1 returns a transfer changeset" do
      transfer = transfer_fixture()
      assert %Ecto.Changeset{} = Transfers.change_transfer(transfer)
    end
  end
end
