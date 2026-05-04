defmodule CashLens.Transactions.TransferMatcherTest do
  use CashLens.DataCase, async: false
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures
  import CashLens.CategoriesFixtures

  setup do
    category = category_fixture(%{name: "Transfer", slug: "transfer"})
    acc1 = account_fixture(%{name: "Checking"})
    acc2 = account_fixture(%{name: "Ouro", slug: "ouro"})

    %{category: category, acc1: acc1, acc2: acc2}
  end

  describe "match_transfers/1" do
    test "links matching transactions in a batch", %{category: cat, acc1: a1, acc2: a2} do
      tx1 =
        transaction_fixture(%{
          account_id: a1.id,
          category_id: cat.id,
          amount: Decimal.new("200.00"),
          date: ~D[2026-04-01]
        })

      tx2 =
        transaction_fixture(%{
          account_id: a2.id,
          category_id: cat.id,
          amount: Decimal.new("-200.00"),
          date: ~D[2026-04-01]
        })

      # Reset transfer_key so we can test match_transfers directly
      Repo.update_all(
        from(t in CashLens.Transactions.Transaction, where: t.id in [^tx1.id, ^tx2.id]),
        set: [transfer_key: nil]
      )

      tx1 = Repo.get(Transaction, tx1.id)
      tx2 = Repo.get(Transaction, tx2.id)

      TransferMatcher.match_transfers([tx1, tx2])

      updated_tx1 = Repo.get(Transaction, tx1.id)
      updated_tx2 = Repo.get(Transaction, tx2.id)

      assert updated_tx1.transfer_key != nil
      assert updated_tx1.transfer_key == updated_tx2.transfer_key
    end

    test "skips already-matched transactions", %{category: cat, acc1: a1} do
      existing_key = Ecto.UUID.generate()
      tx = transaction_fixture(%{account_id: a1.id, category_id: cat.id})

      Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
        set: [transfer_key: existing_key]
      )

      tx = Repo.get(Transaction, tx.id)

      TransferMatcher.match_transfers([tx])

      updated = Repo.get(Transaction, tx.id)
      assert updated.transfer_key == existing_key
    end

    test "skips transactions with nil id", %{category: cat} do
      tx = %Transaction{id: nil, category_id: cat.id, transfer_key: nil}
      assert TransferMatcher.match_transfers([tx]) in [:ok, nil]
    end

    test "skips transactions with nil category_id", %{acc1: a1} do
      tx = transaction_fixture(%{account_id: a1.id, category_id: nil})
      TransferMatcher.match_transfers([tx])
      updated = Repo.get(Transaction, tx.id)
      assert is_nil(updated.transfer_key)
    end

    test "skips transactions with non-transfer category", %{acc1: a1} do
      other_cat = category_fixture(%{name: "Food", slug: "food"})
      tx = transaction_fixture(%{account_id: a1.id, category_id: other_cat.id})
      TransferMatcher.match_transfers([tx])
      updated = Repo.get(Transaction, tx.id)
      assert is_nil(updated.transfer_key)
    end

    test "handles empty list" do
      assert TransferMatcher.match_transfers([]) in [:ok, nil]
    end

    test "does nothing when transfer category does not exist" do
      Repo.delete_all(from c in CashLens.Categories.Category, where: c.slug == "transfer")
      assert is_nil(TransferMatcher.match_transfers([]))
    end
  end

  describe "match_transfer/1" do
    test "automatically links two existing transactions upon creation", %{
      category: cat,
      acc1: a1,
      acc2: a2
    } do
      tx1 =
        transaction_fixture(%{
          account_id: a1.id,
          category_id: cat.id,
          amount: Decimal.new("100.00"),
          date: ~D[2026-03-01]
        })

      tx2 =
        transaction_fixture(%{
          account_id: a2.id,
          category_id: cat.id,
          amount: Decimal.new("-100.00"),
          date: ~D[2026-03-01]
        })

      # Verify both transactions were automatically linked upon second creation
      updated_tx1 = Repo.get(Transaction, tx1.id)
      updated_tx2 = Repo.get(Transaction, tx2.id)

      assert updated_tx1.transfer_key != nil
      assert updated_tx1.transfer_key == updated_tx2.transfer_key
    end

    test "automatically creates a virtual twin for BB MM OURO upon creation", %{
      category: cat,
      acc1: a1
    } do
      # Create target account "BB MM Ouro"
      ouro_acc = account_fixture(%{name: "BB MM Ouro"})

      tx =
        transaction_fixture(%{
          account_id: a1.id,
          category_id: cat.id,
          description: "BB MM OURO TRANSFER",
          amount: Decimal.new("-50.00")
        })

      # The twin should already be created because create_transaction triggers TransferMatcher
      updated_tx = Repo.get(Transaction, tx.id)
      assert updated_tx.transfer_key != nil

      # Verify twin was created in the correct account
      twin = Repo.get_by(Transaction, account_id: ouro_acc.id)
      assert twin != nil
      assert twin.amount == Decimal.new("50.00")
      assert twin.transfer_key == updated_tx.transfer_key
    end

    test "ignores transactions with non-transfer category", %{acc1: a1} do
      cat = category_fixture(%{name: "Other", slug: "other"})
      tx = transaction_fixture(%{account_id: a1.id, category_id: cat.id})

      assert :not_a_transfer == TransferMatcher.match_transfer(tx)
    end
  end
end
