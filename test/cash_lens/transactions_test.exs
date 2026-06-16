defmodule CashLens.TransactionsTest do
  use CashLens.DataCase, async: false

  alias CashLens.AccountsFixtures
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  import CashLens.TransactionsFixtures

  setup do
    # Clear global patterns to avoid CI collisions
    Repo.delete_all(CashLens.Transactions.BulkIgnorePattern)
    :ok
  end

  describe "new-code coverage" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    test "list_reimbursement_credit_candidates/1 excludes transfer/salary categories and their children" do
      transfer = category_fixture(%{name: "Transfer", slug: "transfer"})
      _child = category_fixture(%{name: "Sub", slug: "sub-transfer", parent_id: transfer.id})

      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        amount: "100.00",
        description: "Recebimento",
        category_id: nil
      })

      transaction_fixture(%{
        account_id: acc.id,
        amount: "200.00",
        description: "Movido",
        category_id: transfer.id
      })

      candidates = Transactions.list_reimbursement_credit_candidates()
      descriptions = Enum.map(candidates, & &1.description)
      refute "Movido" in descriptions
    end

    test "list_all_transactions/1 handles partial and invalid date ranges" do
      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        amount: "-10.00",
        date: ~D[2026-03-10],
        description: "DR"
      })

      # date_from present, date_to empty -> no upper bound applied
      assert [_ | _] =
               Transactions.list_all_transactions(%{"date_from" => "2026-01-01", "date_to" => ""})

      # nil upper bound
      assert [_ | _] =
               Transactions.list_all_transactions(%{
                 "date_from" => "2026-01-01",
                 "date_to" => nil
               })

      # invalid iso date falls through to the unfiltered query
      assert is_list(
               Transactions.list_all_transactions(%{
                 "date_from" => "nope",
                 "date_to" => "also-bad"
               })
             )
    end

    test "suggest_installment_link/1 suggests an in-progress group" do
      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "ACADEMIA",
          total_amount: "300.00",
          installments: 3,
          start_date: Date.utc_today()
        })

      tx = transaction_fixture(%{amount: "-100.00", description: "ACADEMIA MENSALIDADE"})

      suggestion = Transactions.suggest_installment_link(tx)
      assert suggestion.group_id == group.id
      assert suggestion.next_installment == 1
      assert suggestion.total_installments == 3
    end

    test "suggest_installment_link/1 returns nil for completed groups and no match" do
      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "COMPLETO",
          total_amount: "200.00",
          installments: 2,
          start_date: Date.utc_today()
        })

      acc = account_fixture()

      for d <- ["COMPLETO a", "COMPLETO b"] do
        tx = transaction_fixture(%{account_id: acc.id, amount: "-100.00", description: d})

        Repo.update_all(
          from(t in Transaction, where: t.id == ^tx.id),
          set: [installment_group_id: group.id]
        )
      end

      completed_tx = transaction_fixture(%{amount: "-100.00", description: "COMPLETO c"})
      assert is_nil(Transactions.suggest_installment_link(completed_tx))

      no_match = transaction_fixture(%{amount: "-100.00", description: "NADA A VER"})
      assert is_nil(Transactions.suggest_installment_link(no_match))
    end
  end

  describe "transactions" do
    test "update_transaction/2 updates notes" do
      transaction = transaction_fixture()

      assert {:ok, %Transaction{} = updated} =
               Transactions.update_transaction(transaction, %{notes: "some notes"})

      assert updated.notes == "some notes"
    end

    test "create_transaction/1 with notes" do
      account = CashLens.AccountsFixtures.account_fixture()

      valid_attrs = %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: account.id,
        notes: "initial notes"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.notes == "initial notes"
    end
  end

  describe "list_transactions/1" do
    test "filters by search (description)" do
      transaction_fixture(%{description: "Supermarket shopping"})
      t2 = transaction_fixture(%{description: "Pharmacy bill"})

      results = Transactions.list_transactions(%{"search" => "pharmacy"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t2.id
    end

    test "filters by amount" do
      # Exact amount with dot
      t1 = transaction_fixture(%{amount: "100.50"})
      # Negative amount
      t2 = transaction_fixture(%{amount: "-100.50"})
      # Positive integer match candidate
      t3 = transaction_fixture(%{amount: "166.47"})
      # Negative integer match candidate
      t4 = transaction_fixture(%{amount: "-166.87"})
      # Exact amount with comma candidate
      t5 = transaction_fixture(%{amount: "50.75"})
      # Distractor
      _t6 = transaction_fixture(%{amount: "200.00"})

      # Exact match with dot
      results = Transactions.list_transactions(%{"amount" => "100.50"})
      assert length(results) == 2
      assert Enum.any?(results, &(&1.id == t1.id))
      assert Enum.any?(results, &(&1.id == t2.id))

      # Exact match with comma
      results = Transactions.list_transactions(%{"amount" => "50,75"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t5.id

      # Integer part search (166 should match 166.47 and -166.87)
      results = Transactions.list_transactions(%{"amount" => "166"})
      assert length(results) == 2
      assert Enum.any?(results, &(&1.id == t3.id))
      assert Enum.any?(results, &(&1.id == t4.id))
    end

    test "filters by type (debit/credit)" do
      t1 = transaction_fixture(%{amount: "-50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})

      results = Transactions.list_transactions(%{"type" => "debit"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))

      results = Transactions.list_transactions(%{"type" => "credit"})
      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
    end

    test "filters by amount range" do
      t1 = transaction_fixture(%{amount: "50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})
      t3 = transaction_fixture(%{amount: "250.00"})

      results = Transactions.list_transactions(%{"amount_min" => 100, "amount_max" => 200})
      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t3.id))
    end

    test "filters by reimbursement status" do
      t1 = transaction_fixture(%{reimbursement_status: "pending"})
      t2 = transaction_fixture(%{reimbursement_status: "completed"})

      results = Transactions.list_transactions(%{"reimbursement_status" => "pending"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by category nil" do
      t1 = transaction_fixture(%{category_id: nil})
      category = CashLens.CategoriesFixtures.category_fixture()
      t2 = transaction_fixture(%{category_id: category.id})

      results = Transactions.list_transactions(%{"category_id" => "nil"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by account" do
      account = AccountsFixtures.account_fixture()
      t1 = transaction_fixture(%{account_id: account.id})
      t2 = transaction_fixture()

      results = Transactions.list_transactions(%{"account_id" => account.id})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by date" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(%{"date" => ~D[2026-01-01]})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "sorts by date asc" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(%{"sort_order" => "asc"})
      # t1 should come before t2 in asc order
      idx1 = Enum.find_index(results, &(&1.id == t1.id))
      idx2 = Enum.find_index(results, &(&1.id == t2.id))
      assert idx1 < idx2
    end

    test "filters by month and year" do
      t1 = transaction_fixture(%{date: ~D[2026-01-15]})
      t2 = transaction_fixture(%{date: ~D[2026-02-15]})

      results = Transactions.list_transactions(%{"month" => "1", "year" => "2026"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end
  end

  describe "summaries" do
    test "get_monthly_summary/2 returns correct totals" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})
      transaction_fixture(%{amount: "-40.00", date: ~D[2026-03-15], category_id: category.id})

      summary = Transactions.get_monthly_summary(~D[2026-03-01])
      assert summary.income == Decimal.new("100.00")
      assert summary.expenses == Decimal.new("40.00")
      assert summary.month == ~D[2026-03-01]
    end

    test "get_monthly_summary/2 with filter overrides" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})

      summary = Transactions.get_monthly_summary(nil, %{"month" => "3", "year" => "2026"})
      assert summary.income == Decimal.new("100.00")
    end

    test "get_monthly_summary/2 with category_id nil filter bypasses date range" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "50.00", date: ~D[2025-06-10], category_id: category.id})

      normal_summary = Transactions.get_monthly_summary(~D[2026-03-01])
      bypass_summary = Transactions.get_monthly_summary(~D[2026-03-01], %{"category_id" => "nil"})

      assert normal_summary.income == Decimal.new("0")
      assert bypass_summary.income == Decimal.new("50.00")
    end

    test "get_monthly_summary/2 with unmatched_transfers filter bypasses date range" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "75.00", date: ~D[2025-06-10], category_id: category.id})

      normal_summary = Transactions.get_monthly_summary(~D[2026-03-01])

      bypass_summary =
        Transactions.get_monthly_summary(~D[2026-03-01], %{"unmatched_transfers" => "true"})

      assert normal_summary.income == Decimal.new("0")
      assert bypass_summary.income == Decimal.new("75.00")
    end

    test "get_historical_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-01-10], category_id: category.id})
      transaction_fixture(%{amount: "-50.00", date: ~D[2026-01-20], category_id: category.id})

      results = Transactions.get_historical_summary()

      assert Enum.any?(results, fn r ->
               r.month == 1 && r.year == 2026 && r.income == Decimal.new("100.00")
             end)
    end

    test "get_historical_category_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})
      transaction_fixture(%{amount: "-30.00", date: ~D[2026-01-10], category_id: category.id})

      results = Transactions.get_historical_category_summary()
      assert results != []
    end
  end

  describe "additional operations" do
    test "list_recent_transactions/1" do
      transaction_fixture()
      assert length(Transactions.list_recent_transactions(1)) == 1
    end

    test "reapply_auto_categorization/0 applies transfer rules and creates mirror when category is transfer" do
      transfer_cat =
        CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer", slug: "transfer"})

      source = AccountsFixtures.account_fixture()
      destination = AccountsFixtures.account_fixture()

      # Create a transfer rule
      {:ok, _rule} =
        Transactions.create_transfer_rule(%{
          label: "Reapply rule",
          description_patterns: ["pix transfer text"],
          source_account_id: source.id,
          destination_account_id: destination.id,
          create_mirror: true
        })

      # Insert an uncategorized transaction matching the transfer rule description
      tx =
        transaction_fixture(%{
          account_id: source.id,
          description: "pix transfer text",
          category_id: nil
        })

      assert tx.category_id == nil

      # Reapply auto-categorization
      assert Transactions.reapply_auto_categorization() == :ok

      # Verify it was categorized as transfer and a mirror was created
      updated_tx = Repo.get!(Transaction, tx.id)
      assert updated_tx.category_id == transfer_cat.id
      refute is_nil(updated_tx.transfer_key)

      # A mirror transaction in destination must now exist
      [mirror] = Repo.all(from t in Transaction, where: t.account_id == ^destination.id)
      assert mirror.transfer_key == updated_tx.transfer_key
      assert mirror.category_id == transfer_cat.id
    end

    test "update_transaction_category/2" do
      t = transaction_fixture()
      c = CashLens.CategoriesFixtures.category_fixture()
      assert {:ok, updated} = Transactions.update_transaction_category(t.id, c.id)
      assert updated.category_id == c.id
    end

    test "update_transaction_category/2 sets reimbursement_status to pending for reimbursable category" do
      t = transaction_fixture(%{reimbursement_status: nil})
      c = CashLens.CategoriesFixtures.category_fixture(%{default_reimbursable: true})
      assert {:ok, updated} = Transactions.update_transaction_category(t.id, c.id)
      assert updated.reimbursement_status == "pending"
    end

    test "unlink_reimbursement_by_key/1 handles nil" do
      assert Transactions.unlink_reimbursement_by_key(nil) == :ok
    end

    test "unlink_reimbursement_by_key/1 unlinks transactions" do
      key = Ecto.UUID.generate()

      t1 =
        transaction_fixture(%{
          amount: "-50.00",
          reimbursement_link_key: key,
          reimbursement_status: "completed"
        })

      t2 =
        transaction_fixture(%{
          amount: "50.00",
          reimbursement_link_key: key,
          reimbursement_status: "completed"
        })

      assert Transactions.unlink_reimbursement_by_key(key) == :ok

      t1_after = Transactions.get_transaction!(t1.id)
      t2_after = Transactions.get_transaction!(t2.id)

      assert t1_after.reimbursement_link_key == nil
      assert t1_after.reimbursement_status == "pending"
      assert t2_after.reimbursement_link_key == nil
      assert t2_after.reimbursement_status == nil
    end

    test "create_transaction/1 blocks an accidental manual double-submit" do
      account = AccountsFixtures.account_fixture()

      attrs = %{
        date: ~D[2026-02-23],
        description: "duplicate",
        amount: "100",
        account_id: account.id
      }

      # The manual single-create path always uses occurrence index 0, so an
      # identical second submit collides on the unique fingerprint and is
      # reported as a duplicate (guards against accidental double-clicks). This
      # deliberately differs from the import path, which preserves legitimate
      # repeats via per-batch occurrence indices.
      assert {:ok, %Transaction{}} = Transactions.create_transaction(attrs)
      assert {:ok, :duplicate} = Transactions.create_transaction(attrs)

      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "create_transaction/1 reports :duplicate on a fingerprint collision" do
      account = AccountsFixtures.account_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        date: ~D[2026-02-23],
        description: "collide",
        amount: "100",
        account_id: account.id
      }

      # Pre-seed a row carrying the fingerprint that create_transaction will
      # compute at occurrence index 0, but with a DIFFERENT dedup_key so the
      # occurrence count stays 0. This simulates the concurrent-insert race the
      # :duplicate branch guards against.
      colliding_fp = Transaction.fingerprint(attrs, 0)

      {1, _} =
        Repo.insert_all(Transaction, [
          %{
            id: Ecto.UUID.generate(),
            account_id: account.id,
            date: ~D[2026-02-23],
            description: "other",
            amount: Decimal.new("100"),
            dedup_key: "decoy-key",
            fingerprint: colliding_fp,
            inserted_at: now,
            updated_at: now
          }
        ])

      assert {:ok, :duplicate} = Transactions.create_transaction(attrs)
    end
  end

  describe "bulk ignore patterns" do
    test "list_bulk_ignore_patterns/0 returns all patterns" do
      unique_pattern = "UNIQUE_#{System.unique_integer([:positive])}"
      pattern = insert_bulk_ignore_pattern(%{pattern: unique_pattern})
      assert Enum.any?(Transactions.list_bulk_ignore_patterns(), &(&1.id == pattern.id))
    end

    test "list_transactions handles various empty string/nil filters" do
      transaction_fixture(%{description: "test"})
      # Test empty strings and nil filters
      filters = %{
        "account_id" => "",
        "category_id" => "",
        "search" => "",
        "date" => "",
        "amount" => "",
        "type" => "",
        "reimbursement_status" => "",
        "unmatched_transfers" => "false",
        "month" => "",
        "year" => ""
      }

      results = Transactions.list_transactions(filters)
      assert results != []
    end

    test "filter_unmatched_transfers handles non-true value" do
      transaction_fixture(%{description: "test"})
      results = Transactions.list_transactions(%{"unmatched_transfers" => "false"})
      assert results != []
    end

    test "create_bulk_ignore_pattern/1 handles invalid pattern" do
      # L16: bulk ignore pattern changeset invalid
      assert {:error, _} = Transactions.create_bulk_ignore_pattern(%{pattern: ""})
    end
  end

  describe "crud operations" do
    test "create_transaction/1 with valid data" do
      account = AccountsFixtures.account_fixture()

      valid_attrs = %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: account.id
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2026-02-23]
    end

    test "update_transaction/2" do
      transaction = transaction_fixture()

      assert {:ok, %Transaction{}} =
               Transactions.update_transaction(transaction, %{description: "new"})
    end

    test "delete_transaction/1" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Transactions.delete_transaction(transaction)
    end

    test "count_pending_transactions/0" do
      transaction_fixture(%{category_id: nil})
      assert Transactions.count_pending_transactions() >= 1
    end
  end
end
