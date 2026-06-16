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
      assert TransferMatcher.match_transfers([tx]) in [:ok, nil, []]
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
      assert TransferMatcher.match_transfers([]) in [:ok, nil, []]
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

    test "does not link when amounts are not exact opposites", %{
      category: cat,
      acc1: a1,
      acc2: a2
    } do
      transaction_fixture(%{
        account_id: a1.id,
        category_id: cat.id,
        amount: Decimal.new("-50.00"),
        date: ~D[2026-05-01]
      })

      tx =
        transaction_fixture(%{
          account_id: a2.id,
          category_id: cat.id,
          # Not the exact opposite of -50.00
          amount: Decimal.new("49.00"),
          date: ~D[2026-05-01]
        })

      tx = Repo.get(Transaction, tx.id)
      assert TransferMatcher.match_transfer(tx) == :no_twin_found
      assert is_nil(Repo.get(Transaction, tx.id).transfer_key)
    end

    test "ignores transactions with non-transfer category", %{acc1: a1} do
      cat = category_fixture(%{name: "Other", slug: "other"})
      tx = transaction_fixture(%{account_id: a1.id, category_id: cat.id})

      assert :not_a_transfer == TransferMatcher.match_transfer(tx)
    end

    test "returns :no_twin_found when no opposite transaction exists", %{
      category: cat,
      acc1: a1
    } do
      tx =
        transaction_fixture(%{
          account_id: a1.id,
          category_id: cat.id,
          description: "TRANSFER SEM PAR",
          amount: Decimal.new("-50.00")
        })

      tx = Repo.get(Transaction, tx.id)
      assert is_nil(tx.transfer_key)
      assert TransferMatcher.match_transfer(tx) == :no_twin_found
    end

    test "does not link transactions on different dates", %{category: cat, acc1: a1, acc2: a2} do
      transaction_fixture(%{
        account_id: a1.id,
        category_id: cat.id,
        amount: Decimal.new("-100.00"),
        date: ~D[2026-06-01]
      })

      tx =
        transaction_fixture(%{
          account_id: a2.id,
          category_id: cat.id,
          amount: Decimal.new("100.00"),
          date: ~D[2026-06-02]
        })

      tx = Repo.get(Transaction, tx.id)
      assert TransferMatcher.match_transfer(tx) == :no_twin_found
      assert is_nil(Repo.get(Transaction, tx.id).transfer_key)
    end

    test "returns :no_match for transaction with nil id" do
      assert TransferMatcher.match_transfer(%Transaction{id: nil}) == :no_match
    end

    test "categorizes both transactions as transfer when linking a matched pair", %{
      category: cat,
      acc1: a1,
      acc2: a2
    } do
      tx1 =
        transaction_fixture(%{
          account_id: a1.id,
          category_id: nil,
          amount: Decimal.new("150.00"),
          date: ~D[2026-03-01]
        })

      tx2 =
        transaction_fixture(%{
          account_id: a2.id,
          category_id: cat.id,
          amount: Decimal.new("-150.00"),
          date: ~D[2026-03-01]
        })

      updated_tx1 = Repo.get(Transaction, tx1.id)
      updated_tx2 = Repo.get(Transaction, tx2.id)

      assert updated_tx1.transfer_key != nil
      assert updated_tx1.transfer_key == updated_tx2.transfer_key
      assert updated_tx1.category_id == cat.id
      assert updated_tx2.category_id == cat.id
    end
  end
end
