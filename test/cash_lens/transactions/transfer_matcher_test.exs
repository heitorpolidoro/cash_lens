defmodule CashLens.Transactions.TransferMatcherTest do
  use CashLens.DataCase, async: true
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.Transaction
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures
  import CashLens.CategoriesFixtures

  setup do
    category = category_fixture(%{name: "Transfer", slug: "transfer"})
    acc1 = account_fixture(%{name: "Checking"})
    acc2 = account_fixture(%{name: "Ouro", slug: "ouro"})
    
    %{category: category, acc1: acc1, acc2: acc2}
  end

  describe "match_transfer/1" do
    test "automatically links two existing transactions upon creation", %{category: cat, acc1: a1, acc2: a2} do
      tx1 = transaction_fixture(%{
        account_id: a1.id, 
        category_id: cat.id, 
        amount: Decimal.new("100.00"),
        date: ~D[2026-03-01]
      })
      
      tx2 = transaction_fixture(%{
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

    test "automatically creates a virtual twin for BB MM OURO upon creation", %{category: cat, acc1: a1} do
      # Create target account "BB MM Ouro"
      ouro_acc = account_fixture(%{name: "BB MM Ouro"})
      
      tx = transaction_fixture(%{
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
