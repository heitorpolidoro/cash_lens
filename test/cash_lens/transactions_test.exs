defmodule CashLens.TransactionsTest do
  use CashLens.DataCase, async: false

  defp user, do: CashLens.Repo.get!(CashLens.Users.User, CashLens.Repo.current_user_id())

  alias CashLens.AccountsFixtures
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  import CashLens.TransactionsFixtures

  setup do
    # Clear global patterns to avoid CI collisions
    Repo.delete_all(CashLens.Transactions.BulkIgnorePattern)
    :ok
  end

  describe "latest_transaction_date/1" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "returns the most recent date among the account's transactions" do
      account = account_fixture()

      transaction_fixture(%{account_id: account.id, date: ~D[2026-01-10], amount: "-10"})
      transaction_fixture(%{account_id: account.id, date: ~D[2026-03-05], amount: "-20"})
      transaction_fixture(%{account_id: account.id, date: ~D[2026-02-01], amount: "-30"})

      assert Transactions.latest_transaction_date(user(), account.id) == ~D[2026-03-05]
    end

    test "returns nil when the account has no transactions" do
      account = account_fixture()

      assert Transactions.latest_transaction_date(user(), account.id) == nil
    end
  end

  describe "new-code coverage" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    test "list_reimbursement_credit_candidates/1 excludes transfer/salary/credit card categories and their children" do
      transfer = category_fixture(%{name: "Transfer", slug: "transfer"})
      _child = category_fixture(%{name: "Sub", slug: "sub-transfer", parent_id: transfer.id})
      cc = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

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

      transaction_fixture(%{
        account_id: acc.id,
        amount: "300.00",
        description: "Fatura CC",
        category_id: cc.id
      })

      candidates = Transactions.list_reimbursement_credit_candidates(user())
      descriptions = Enum.map(candidates, & &1.description)
      refute "Movido" in descriptions
      refute "Fatura CC" in descriptions
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
               Transactions.list_all_transactions(user(), %{
                 "date_from" => "2026-01-01",
                 "date_to" => ""
               })

      # nil upper bound
      assert [_ | _] =
               Transactions.list_all_transactions(user(), %{
                 "date_from" => "2026-01-01",
                 "date_to" => nil
               })

      # invalid iso date falls through to the unfiltered query
      assert is_list(
               Transactions.list_all_transactions(user(), %{
                 "date_from" => "nope",
                 "date_to" => "also-bad"
               })
             )
    end

    test "suggest_installment_link/1 suggests an in-progress group" do
      {:ok, group} =
        CashLens.Installments.create_installment_group(user(), %{
          description_pattern: "ACADEMIA",
          total_amount: "300.00",
          installments: 3,
          start_date: Date.utc_today()
        })

      tx = transaction_fixture(%{amount: "-100.00", description: "ACADEMIA MENSALIDADE"})

      suggestion = Transactions.suggest_installment_link(user(), tx)
      assert suggestion.group_id == group.id
      assert suggestion.next_installment == 1
      assert suggestion.total_installments == 3
    end

    test "suggest_installment_link/1 returns nil for completed groups and no match" do
      {:ok, group} =
        CashLens.Installments.create_installment_group(user(), %{
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
      assert is_nil(Transactions.suggest_installment_link(user(), completed_tx))

      no_match = transaction_fixture(%{amount: "-100.00", description: "NADA A VER"})
      assert is_nil(Transactions.suggest_installment_link(user(), no_match))
    end
  end

  describe "transactions" do
    test "update_transaction/2 updates notes" do
      transaction = transaction_fixture()

      assert {:ok, %Transaction{} = updated} =
               Transactions.update_transaction(user(), transaction, %{notes: "some notes"})

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

      assert {:ok, %Transaction{} = transaction} =
               Transactions.create_transaction(user(), valid_attrs)

      assert transaction.notes == "initial notes"
    end
  end

  describe "list_transactions/1" do
    test "filters by search (description)" do
      transaction_fixture(%{description: "Supermarket shopping"})
      t2 = transaction_fixture(%{description: "Pharmacy bill"})

      results = Transactions.list_transactions(user(), %{"search" => "pharmacy"})
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
      results = Transactions.list_transactions(user(), %{"amount" => "100.50"})
      assert length(results) == 2
      assert Enum.any?(results, &(&1.id == t1.id))
      assert Enum.any?(results, &(&1.id == t2.id))

      # Exact match with comma
      results = Transactions.list_transactions(user(), %{"amount" => "50,75"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t5.id

      # Integer part search (166 should match 166.47 and -166.87)
      results = Transactions.list_transactions(user(), %{"amount" => "166"})
      assert length(results) == 2
      assert Enum.any?(results, &(&1.id == t3.id))
      assert Enum.any?(results, &(&1.id == t4.id))
    end

    test "filters by type (debit/credit)" do
      t1 = transaction_fixture(%{amount: "-50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})

      results = Transactions.list_transactions(user(), %{"type" => "debit"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))

      results = Transactions.list_transactions(user(), %{"type" => "credit"})
      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
    end

    test "filters by amount range" do
      t1 = transaction_fixture(%{amount: "50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})
      t3 = transaction_fixture(%{amount: "250.00"})

      results =
        Transactions.list_transactions(user(), %{"amount_min" => 100, "amount_max" => 200})

      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t3.id))
    end

    test "filters by reimbursement status" do
      t1 = transaction_fixture(%{reimbursement_status: "pending"})
      t2 = transaction_fixture(%{reimbursement_status: "completed"})

      results = Transactions.list_transactions(user(), %{"reimbursement_status" => "pending"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by category nil" do
      t1 = transaction_fixture(%{category_id: nil})
      category = CashLens.CategoriesFixtures.category_fixture()
      t2 = transaction_fixture(%{category_id: category.id})

      results = Transactions.list_transactions(user(), %{"category_id" => "nil"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by account" do
      account = AccountsFixtures.account_fixture()
      t1 = transaction_fixture(%{account_id: account.id})
      t2 = transaction_fixture()

      results = Transactions.list_transactions(user(), %{"account_id" => account.id})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by date" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(user(), %{"date" => ~D[2026-01-01]})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "sorts by date asc" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(user(), %{"sort_order" => "asc"})
      # t1 should come before t2 in asc order
      idx1 = Enum.find_index(results, &(&1.id == t1.id))
      idx2 = Enum.find_index(results, &(&1.id == t2.id))
      assert idx1 < idx2
    end

    test "filters by month and year" do
      t1 = transaction_fixture(%{date: ~D[2026-01-15]})
      t2 = transaction_fixture(%{date: ~D[2026-02-15]})

      results = Transactions.list_transactions(user(), %{"month" => "1", "year" => "2026"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end
  end

  describe "summaries" do
    test "get_monthly_summary/2 returns correct totals" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})
      transaction_fixture(%{amount: "-40.00", date: ~D[2026-03-15], category_id: category.id})

      summary = Transactions.get_monthly_summary(user(), ~D[2026-03-01])
      assert summary.income == Decimal.new("100.00")
      assert summary.expenses == Decimal.new("40.00")
      assert summary.month == ~D[2026-03-01]
    end

    test "get_monthly_summary/2 with filter overrides" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})

      summary = Transactions.get_monthly_summary(user(), nil, %{"month" => "3", "year" => "2026"})
      assert summary.income == Decimal.new("100.00")
    end

    test "get_monthly_summary/2 with category_id nil filter bypasses date range" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "50.00", date: ~D[2025-06-10], category_id: category.id})

      normal_summary = Transactions.get_monthly_summary(user(), ~D[2026-03-01])

      bypass_summary =
        Transactions.get_monthly_summary(user(), ~D[2026-03-01], %{"category_id" => "nil"})

      assert normal_summary.income == Decimal.new("0")
      assert bypass_summary.income == Decimal.new("50.00")
    end

    test "get_monthly_summary/2 with unmatched_transfers filter bypasses date range" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "75.00", date: ~D[2025-06-10], category_id: category.id})

      normal_summary = Transactions.get_monthly_summary(user(), ~D[2026-03-01])

      bypass_summary =
        Transactions.get_monthly_summary(user(), ~D[2026-03-01], %{
          "unmatched_transfers" => "true"
        })

      assert normal_summary.income == Decimal.new("0")
      assert bypass_summary.income == Decimal.new("75.00")
    end

    test "get_monthly_summary/2 income - expenses matches bank cash flow" do
      salary = CashLens.CategoriesFixtures.category_fixture(%{slug: "salary", type: "fixed"})
      rent = CashLens.CategoriesFixtures.category_fixture(%{slug: "rent", type: "fixed"})

      cc =
        CashLens.CategoriesFixtures.category_fixture(%{slug: "cartao-de-credito", type: "fixed"})

      groceries =
        CashLens.CategoriesFixtures.category_fixture(%{slug: "groceries", type: "variable"})

      checking = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: false})
      card = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true})

      # Bank transactions: +5000 salary, -1500 rent, -1200 card bill payment
      transaction_fixture(%{
        account_id: checking.id,
        category_id: salary.id,
        amount: "5000.00",
        date: ~D[2026-03-05]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: rent.id,
        amount: "-1500.00",
        date: ~D[2026-03-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-1200.00",
        date: ~D[2026-03-20]
      })

      # Card transactions: -400 groceries, +1200 card bill payment mirror
      transaction_fixture(%{
        account_id: card.id,
        category_id: groceries.id,
        amount: "-400.00",
        date: ~D[2026-03-15]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: cc.id,
        amount: "1200.00",
        date: ~D[2026-03-20]
      })

      summary = Transactions.get_monthly_summary(user(), ~D[2026-03-01])
      assert Decimal.equal?(summary.income, Decimal.new("5000.00"))
      assert Decimal.equal?(summary.expenses, Decimal.new("2700.00"))
      # Net bank cash flow: 5000 - 2700 = 2300
      net_cash_flow = Decimal.sub(summary.income, summary.expenses)
      assert Decimal.equal?(net_cash_flow, Decimal.new("2300.00"))
    end

    test "get_historical_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-01-10], category_id: category.id})
      transaction_fixture(%{amount: "-50.00", date: ~D[2026-01-20], category_id: category.id})

      results = Transactions.get_historical_summary(user())

      assert Enum.any?(results, fn r ->
               r.month == 1 && r.year == 2026 && r.income == Decimal.new("100.00")
             end)
    end

    test "get_historical_category_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})
      transaction_fixture(%{amount: "-30.00", date: ~D[2026-01-10], category_id: category.id})

      results = Transactions.get_historical_category_summary(user())
      assert results != []
    end
  end

  describe "additional operations" do
    test "list_recent_transactions/1" do
      transaction_fixture()
      assert length(Transactions.list_recent_transactions(user(), 1)) == 1
    end

    test "reapply_auto_categorization/0 applies transfer rules and creates mirror when category is transfer" do
      transfer_cat =
        CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer", slug: "transfer"})

      source = AccountsFixtures.account_fixture()
      destination = AccountsFixtures.account_fixture()

      # Create a transfer rule
      {:ok, _rule} =
        Transactions.create_transfer_rule(user(), %{
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
      assert Transactions.reapply_auto_categorization(user()) == :ok

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
      assert {:ok, updated} = Transactions.update_transaction_category(user(), t.id, c.id)
      assert updated.category_id == c.id
    end

    test "update_transaction_category/2 sets reimbursement_status to pending for reimbursable category" do
      t = transaction_fixture(%{reimbursement_status: nil})
      c = CashLens.CategoriesFixtures.category_fixture(%{default_reimbursable: true})
      assert {:ok, updated} = Transactions.update_transaction_category(user(), t.id, c.id)
      assert updated.reimbursement_status == "pending"
    end

    test "unlink_reimbursement_by_key/1 handles nil" do
      assert Transactions.unlink_reimbursement_by_key(user(), nil) == :ok
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

      assert Transactions.unlink_reimbursement_by_key(user(), key) == :ok

      t1_after = Transactions.get_transaction!(user(), t1.id)
      t2_after = Transactions.get_transaction!(user(), t2.id)

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
      assert {:ok, %Transaction{}} = Transactions.create_transaction(user(), attrs)
      assert {:ok, :duplicate} = Transactions.create_transaction(user(), attrs)

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
            user_id: CashLens.Ownership.current_user_id!(),
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

      assert {:ok, :duplicate} = Transactions.create_transaction(user(), attrs)
    end
  end

  describe "bulk ignore patterns" do
    test "list_bulk_ignore_patterns/0 returns all patterns" do
      unique_pattern = "UNIQUE_#{System.unique_integer([:positive])}"
      pattern = insert_bulk_ignore_pattern(%{pattern: unique_pattern})
      assert Enum.any?(Transactions.list_bulk_ignore_patterns(user()), &(&1.id == pattern.id))
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

      results = Transactions.list_transactions(user(), filters)
      assert results != []
    end

    test "filter_unmatched_transfers handles non-true value" do
      transaction_fixture(%{description: "test"})
      results = Transactions.list_transactions(user(), %{"unmatched_transfers" => "false"})
      assert results != []
    end

    test "create_bulk_ignore_pattern/1 handles invalid pattern" do
      # L16: bulk ignore pattern changeset invalid
      assert {:error, _} = Transactions.create_bulk_ignore_pattern(user(), %{pattern: ""})
    end

    test "update_bulk_ignore_pattern/2 persists both fields" do
      pattern =
        insert_bulk_ignore_pattern(%{pattern: "^ANTIGO_#{System.unique_integer([:positive])}"})

      new_source = "^NOVO_#{System.unique_integer([:positive])}"

      assert {:ok, updated} =
               Transactions.update_bulk_ignore_pattern(user(), pattern, %{
                 pattern: new_source,
                 description: "Motivo novo"
               })

      assert updated.pattern == new_source

      reloaded = Transactions.get_bulk_ignore_pattern!(user(), pattern.id)
      assert reloaded.pattern == new_source
      assert reloaded.description == "Motivo novo"
    end

    test "update_bulk_ignore_pattern/2 rejects a regex that does not compile" do
      original = "^VALIDO_#{System.unique_integer([:positive])}"
      pattern = insert_bulk_ignore_pattern(%{pattern: original})

      assert {:error, changeset} =
               Transactions.update_bulk_ignore_pattern(user(), pattern, %{pattern: "[aberto("})

      assert "Regex inválida" in errors_on(changeset).pattern
      assert Transactions.get_bulk_ignore_pattern!(user(), pattern.id).pattern == original
    end

    test "update_bulk_ignore_pattern/2 enforces the unique constraint on pattern" do
      taken = "^TOMADO_#{System.unique_integer([:positive])}"
      insert_bulk_ignore_pattern(%{pattern: taken})

      pattern =
        insert_bulk_ignore_pattern(%{pattern: "^LIVRE_#{System.unique_integer([:positive])}"})

      assert {:error, changeset} =
               Transactions.update_bulk_ignore_pattern(user(), pattern, %{pattern: taken})

      assert errors_on(changeset).pattern != []
      refute Transactions.get_bulk_ignore_pattern!(user(), pattern.id).pattern == taken
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

      assert {:ok, %Transaction{} = transaction} =
               Transactions.create_transaction(user(), valid_attrs)

      assert transaction.date == ~D[2026-02-23]
    end

    test "update_transaction/2" do
      transaction = transaction_fixture()

      assert {:ok, %Transaction{}} =
               Transactions.update_transaction(user(), transaction, %{description: "new"})
    end

    test "delete_transaction/1" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Transactions.delete_transaction(user(), transaction)
    end

    test "count_pending_transactions/0" do
      transaction_fixture(%{category_id: nil})
      assert Transactions.count_pending_transactions(user()) >= 1
    end
  end

  describe "update_transaction_category/2 — credit card matching guard" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    defp cc_category,
      do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

    defp other_category, do: category_fixture(%{name: "Mercado", slug: "mercado"})

    test "links a pending orphan batch when the category becomes Cartão de Crédito" do
      category = cc_category()
      card = account_fixture(%{is_credit_card: true})
      checking = account_fixture(%{is_credit_card: false})

      statement =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          total_a_pagar: Decimal.new("50.00"),
          due_date: ~D[2026-02-05]
        })

      purchase =
        transaction_fixture(%{
          account_id: card.id,
          amount: "-50.00",
          date: ~D[2026-02-01],
          import_batch_id: statement.id
        })

      payment =
        transaction_fixture(%{account_id: checking.id, amount: "-50.00", date: ~D[2026-02-05]})

      {:ok, _} = Transactions.update_transaction_category(user(), payment.id, category.id)

      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
    end

    test "does not call the matcher when the new category is not Cartão de Crédito" do
      category = other_category()
      checking = account_fixture(%{is_credit_card: false})
      tx = transaction_fixture(%{account_id: checking.id, amount: "-50.00", date: ~D[2026-02-05]})

      assert {:ok, updated} = Transactions.update_transaction_category(user(), tx.id, category.id)
      assert updated.category_id == category.id
    end
  end

  describe "reapply_transfer_rules/0 — credit card retry" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    test "retries matching for Cartão de Crédito payments still without children" do
      category = category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})
      card = account_fixture(%{is_credit_card: true})
      checking = account_fixture(%{is_credit_card: false})

      statement =
        CashLens.CreditCardsFixtures.statement_fixture(%{
          account: card,
          total_a_pagar: Decimal.new("50.00"),
          due_date: ~D[2026-02-05]
        })

      purchase =
        transaction_fixture(%{
          account_id: card.id,
          amount: "-50.00",
          date: ~D[2026-02-01],
          import_batch_id: statement.id
        })

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          amount: "-50.00",
          date: ~D[2026-02-05]
        })

      # Set the category directly via Repo (bypassing update_transaction_category's
      # own matching hook) so reapply_transfer_rules/0 is what performs the match.
      {1, _} =
        Repo.update_all(
          from(t in Transaction, where: t.id == ^payment.id),
          set: [category_id: category.id]
        )

      assert is_nil(Repo.get!(Transaction, purchase.id).parent_transaction_id)

      Transactions.reapply_transfer_rules(user())

      assert Repo.get!(Transaction, purchase.id).parent_transaction_id == payment.id
    end
  end

  describe "totals exclude Cartão de Crédito (no double counting)" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    test "get_filtered_summary/1 excludes the payment but counts the itemized purchase" do
      cc = cc_category()
      market = other_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      summary = Transactions.get_filtered_summary(user(), %{})
      assert Decimal.equal?(summary.cards.expenses, Decimal.new("500.00"))
      assert Decimal.equal?(summary.cash.expenses, Decimal.new("0"))
    end

    test "get_monthly_summary/2 includes Cartão de Crédito payments on bank accounts and excludes credit card accounts" do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})
      market = other_category()

      # Bank account pays credit card bill -> cash expense
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      # Credit card purchase -> NOT direct cash expense from bank account
      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-200.00",
        date: ~D[2026-02-11]
      })

      # Credit card mirror payment credit -> NOT cash income
      transaction_fixture(%{
        account_id: card.id,
        category_id: cc.id,
        amount: "500.00",
        date: ~D[2026-02-10]
      })

      summary = Transactions.get_monthly_summary(user(), ~D[2026-02-15])
      assert Decimal.equal?(summary.expenses, Decimal.new("500.00"))
      assert Decimal.equal?(summary.income, Decimal.new("0"))
    end

    test "get_monthly_summary/2 with specific account_id filter filters by that account" do
      cc = cc_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})
      market = other_category()

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-200.00",
        date: ~D[2026-02-11]
      })

      card_summary =
        Transactions.get_monthly_summary(user(), ~D[2026-02-15], %{"account_id" => card.id})

      assert Decimal.equal?(card_summary.expenses, Decimal.new("200.00"))

      checking_summary =
        Transactions.get_monthly_summary(user(), ~D[2026-02-15], %{"account_id" => checking.id})

      assert Decimal.equal?(checking_summary.expenses, Decimal.new("500.00"))
    end

    test "get_historical_summary/1 includes Cartão de Crédito payments on bank accounts and excludes credit card accounts" do
      cc = cc_category()
      market = other_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-500.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "10.00",
        date: ~D[2026-02-12]
      })

      # Credit card purchase on card account should NOT appear in historical cash summary
      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-150.00",
        date: ~D[2026-02-14]
      })

      [row] = Transactions.get_historical_summary(user())
      assert Decimal.equal?(row.income, Decimal.new("10.00"))
      assert Decimal.equal?(row.expenses, Decimal.new("500.00"))
      assert Decimal.equal?(row.balance, Decimal.new("-490.00"))
    end

    test "get_historical_summary/1 includes Cartão de Crédito child category on bank account but ignores card account" do
      cc = cc_category()

      pagamento =
        category_fixture(%{
          name: "Pagamento",
          slug: "cartao-de-credito-pagamento",
          parent_id: cc.id
        })

      market = other_category()
      card = account_fixture(%{is_credit_card: true})
      checking = account_fixture(%{is_credit_card: false})

      # The bank-side debit that pays the card bill.
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-14391.19",
        date: ~D[2026-06-16]
      })

      # The mirror credit inside the card account — not included because card is a credit card account.
      transaction_fixture(%{
        account_id: card.id,
        category_id: pagamento.id,
        amount: "14391.19",
        date: ~D[2026-06-16]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "10.00",
        date: ~D[2026-06-12]
      })

      [row] = Transactions.get_historical_summary(user())
      assert Decimal.equal?(row.income, Decimal.new("10.00"))
      assert Decimal.equal?(row.expenses, Decimal.new("14391.19"))
      assert Decimal.equal?(row.balance, Decimal.new("-14381.19"))
    end

    test "get_month_income_breakdown/2 excludes a Cartão de Crédito child category" do
      cc = cc_category()

      pagamento =
        category_fixture(%{
          name: "Pagamento",
          slug: "cartao-de-credito-pagamento",
          parent_id: cc.id
        })

      market = other_category()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: pagamento.id,
        amount: "14391.19",
        date: ~D[2026-06-16]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "10.00",
        date: ~D[2026-06-12]
      })

      breakdown = Transactions.get_month_income_breakdown(user(), 2026, 6)

      # The rollup groups the child under its PARENT's id, so checking for
      # the child's own id would pass even with the bug present (false
      # negative) — assert on the parent id and the total instead.
      refute Enum.any?(breakdown, &(&1.category_id == cc.id))
      assert Enum.any?(breakdown, &(&1.category_id == market.id))

      total = Enum.reduce(breakdown, Decimal.new("0"), &Decimal.add(&2, &1.total))
      assert Decimal.equal?(total, Decimal.new("10.00"))
    end
  end

  describe "category breakdown excludes transactions with children" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    defp cc_category2,
      do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

    test "get_month_category_breakdown/2 keeps a parent whose only children sit on card accounts" do
      cc = cc_category2()
      uber_cat = category_fixture(%{name: "Transporte", slug: "transporte"})
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: cc.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      child =
        transaction_fixture(%{
          account_id: card.id,
          category_id: uber_cat.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      {1, _} =
        from(t in Transaction, where: t.id == ^child.id)
        |> Repo.update_all(set: [parent_transaction_id: payment.id])

      breakdown = Transactions.get_month_category_breakdown(user(), 2026, 2)

      # The bill payment is the only cash movement of the pair, so it is the one
      # that must be reported; its card-side child is invisible on this screen.
      assert Enum.any?(breakdown, &(&1.category_id == cc.id))
      refute Enum.any?(breakdown, &(&1.category_id == uber_cat.id))
    end

    test "a Cartão de Crédito transaction with no children is reported as a cash expense" do
      cc = cc_category2()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-02-10]
      })

      breakdown = Transactions.get_month_category_breakdown(user(), 2026, 2)
      assert [row] = Enum.filter(breakdown, &(&1.category_id == cc.id))
      assert Decimal.equal?(row.total, Decimal.new("100.00"))
    end

    test "get_historical_category_summary/1 excludes parents with children" do
      cc = cc_category2()
      uber_cat = category_fixture(%{name: "Transporte", slug: "transporte"})
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      payment =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: cc.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      child =
        transaction_fixture(%{
          account_id: card.id,
          category_id: uber_cat.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      {1, _} =
        from(t in Transaction, where: t.id == ^child.id)
        |> Repo.update_all(set: [parent_transaction_id: payment.id])

      [month] = Transactions.get_historical_category_summary(user(), limit: 1)
      category_names = Enum.map(month.categories, & &1.name)

      refute "Cartão de Crédito" in category_names
      assert "Transporte" in category_names
    end
  end

  describe "month breakdowns are a cash-basis view" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    defp cash_basis_cc_category,
      do: category_fixture(%{name: "Cartão de Crédito", slug: "cartao-de-credito"})

    test "neither breakdown reports categorized transactions on credit-card accounts" do
      card = account_fixture(%{is_credit_card: true})
      market = category_fixture(%{name: "Mercado", slug: "mercado"})
      salary = category_fixture(%{name: "Salário", slug: "salario"})

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-100.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: salary.id,
        amount: "100.00",
        date: ~D[2026-02-11]
      })

      refute Enum.any?(
               Transactions.get_month_category_breakdown(user(), 2026, 2),
               &(&1.category_id == market.id)
             )

      refute Enum.any?(
               Transactions.get_month_income_breakdown(user(), 2026, 2),
               &(&1.category_id == salary.id)
             )
    end

    test "neither Uncategorized subquery reports transactions on credit-card accounts" do
      card = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{account_id: card.id, amount: "-100.00", date: ~D[2026-02-10]})
      transaction_fixture(%{account_id: card.id, amount: "100.00", date: ~D[2026-02-11]})

      refute Enum.any?(
               Transactions.get_month_category_breakdown(user(), 2026, 2),
               &(&1.name == "Uncategorized")
             )

      refute Enum.any?(
               Transactions.get_month_income_breakdown(user(), 2026, 2),
               &(&1.name == "Uncategorized")
             )
    end

    test "expenses report the card bill payment but never transfers or initial values" do
      checking = account_fixture(%{is_credit_card: false})
      cc = cash_basis_cc_category()
      transfer = category_fixture(%{name: "Transferência", slug: "transfer"})

      transfer_child =
        category_fixture(%{
          name: "Transferência Pix",
          slug: "transfer-pix",
          parent_id: transfer.id
        })

      initial = category_fixture(%{name: "Saldo Inicial", slug: "initial_value"})

      initial_child =
        category_fixture(%{
          name: "Abertura",
          slug: "initial_value-abertura",
          parent_id: initial.id
        })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: transfer_child.id,
        amount: "-50.00",
        date: ~D[2026-02-11]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: initial_child.id,
        amount: "-25.00",
        date: ~D[2026-02-12]
      })

      breakdown = Transactions.get_month_category_breakdown(user(), 2026, 2)

      assert [row] = Enum.filter(breakdown, &(&1.category_id == cc.id))
      assert Decimal.equal?(row.total, Decimal.new("100.00"))
      refute Enum.any?(breakdown, &(&1.category_id == transfer.id))
      refute Enum.any?(breakdown, &(&1.category_id == initial.id))
    end

    test "income still drops a cartao-de-credito credit landing on a cash account" do
      checking = account_fixture(%{is_credit_card: false})
      cc = cash_basis_cc_category()
      salary = category_fixture(%{name: "Salário", slug: "salario"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "900.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: salary.id,
        amount: "100.00",
        date: ~D[2026-02-11]
      })

      breakdown = Transactions.get_month_income_breakdown(user(), 2026, 2)

      refute Enum.any?(breakdown, &(&1.category_id == cc.id))
      assert Enum.any?(breakdown, &(&1.category_id == salary.id))
    end

    test "get_historical_category_summary/1 still excludes cartao-de-credito spending" do
      checking = account_fixture(%{is_credit_card: false})
      cc = cash_basis_cc_category()

      _ourocard =
        category_fixture(%{
          name: "Ourocard",
          slug: "cartao-de-credito-ourocard",
          parent_id: cc.id
        })

      market = category_fixture(%{name: "Mercado", slug: "mercado"})

      # A lone bill payment: nothing points its parent_transaction_id at it.
      transaction_fixture(%{
        account_id: checking.id,
        category_id: cc.id,
        amount: "-100.00",
        date: ~D[2026-02-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "-40.00",
        date: ~D[2026-02-11]
      })

      names =
        Transactions.get_historical_category_summary(user())
        |> Enum.flat_map(fn month -> Enum.map(month.categories, & &1.name) end)

      assert "Mercado" in names
      refute "Cartão de Crédito" in names
      refute "Ourocard" in names
    end

    test "a cash-account parent with at least one cash-account child stays hidden" do
      checking = account_fixture(%{is_credit_card: false})
      other_checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})
      lump = category_fixture(%{name: "Lote", slug: "lote"})
      market = category_fixture(%{name: "Mercado", slug: "mercado"})

      parent =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: lump.id,
          amount: "-100.00",
          date: ~D[2026-02-10]
        })

      cash_child =
        transaction_fixture(%{
          account_id: other_checking.id,
          category_id: market.id,
          amount: "-60.00",
          date: ~D[2026-02-10]
        })

      card_child =
        transaction_fixture(%{
          account_id: card.id,
          category_id: market.id,
          amount: "-40.00",
          date: ~D[2026-02-10]
        })

      {2, _} =
        from(t in Transaction, where: t.id in ^[cash_child.id, card_child.id])
        |> Repo.update_all(set: [parent_transaction_id: parent.id])

      breakdown = Transactions.get_month_category_breakdown(user(), 2026, 2)

      refute Enum.any?(breakdown, &(&1.category_id == lump.id))
      assert [row] = Enum.filter(breakdown, &(&1.category_id == market.id))
      assert Decimal.equal?(row.total, Decimal.new("60.00"))
    end

    test "list_all_transactions/1 drops credit-card accounts only when asked to" do
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})
      market = category_fixture(%{name: "Mercado", slug: "mercado"})

      cash_tx =
        transaction_fixture(%{
          account_id: checking.id,
          category_id: market.id,
          amount: "-60.00",
          date: ~D[2026-02-10]
        })

      card_tx =
        transaction_fixture(%{
          account_id: card.id,
          category_id: market.id,
          amount: "-40.00",
          date: ~D[2026-02-10]
        })

      unfiltered_ids =
        Transactions.list_all_transactions(user(), %{"category_id" => market.id})
        |> Enum.map(& &1.id)

      assert cash_tx.id in unfiltered_ids
      assert card_tx.id in unfiltered_ids

      filtered_ids =
        Transactions.list_all_transactions(user(), %{
          "category_id" => market.id,
          "cash_accounts_only" => true
        })
        |> Enum.map(& &1.id)

      assert cash_tx.id in filtered_ids
      refute card_tx.id in filtered_ids
    end
  end

  describe "statement_health/0" do
    test "counts uncategorized transactions, receivable reimbursements and unmatched transfers" do
      account = AccountsFixtures.account_fixture()

      transfer_cat =
        CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer", slug: "transfer"})

      other_cat = CashLens.CategoriesFixtures.category_fixture(%{name: "Outra", slug: "outra"})

      # Two uncategorized transactions.
      transaction_fixture(%{account_id: account.id, description: "Sem categoria A"})
      transaction_fixture(%{account_id: account.id, description: "Sem categoria B"})

      # One categorized transaction (must not count as uncategorized).
      transaction_fixture(%{account_id: account.id, category_id: other_cat.id})

      # Two reimbursable expenses awaiting money back.
      expense =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-80.00",
          category_id: other_cat.id
        })

      {:ok, _} =
        Transactions.update_transaction(user(), expense, %{reimbursement_status: "pending"})

      requested =
        transaction_fixture(%{
          account_id: account.id,
          amount: "-20.00",
          category_id: other_cat.id
        })

      {:ok, _} =
        Transactions.update_transaction(user(), requested, %{reimbursement_status: "requested"})

      # An unmatched transfer (categorized as transfer, no transfer_key).
      transaction_fixture(%{
        account_id: account.id,
        amount: "-10.00",
        category_id: transfer_cat.id
      })

      health = Transactions.statement_health(user())

      assert health.uncategorized_count == 2
      assert health.reimbursements_receivable_count == 2
      assert Decimal.equal?(health.reimbursements_receivable_total, Decimal.new("100.00"))
      assert health.unmatched_transfers_count == 1
    end

    test "returns zeroed metrics when there is nothing pending" do
      health = Transactions.statement_health(user())

      assert health.uncategorized_count == 0
      assert health.reimbursements_receivable_count == 0
      assert Decimal.equal?(health.reimbursements_receivable_total, Decimal.new("0"))
      assert health.unmatched_transfers_count == 0
    end
  end

  describe "get_reimbursement_pairs/1" do
    test "groups both sides of a reimbursement by its link key" do
      account = AccountsFixtures.account_fixture()

      expense =
        transaction_fixture(%{account_id: account.id, amount: "-100.00", description: "Consulta"})

      {:ok, expense} =
        Transactions.update_transaction(user(), expense, %{reimbursement_status: "pending"})

      credit =
        transaction_fixture(%{account_id: account.id, amount: "100.00", description: "Credito"})

      {:ok, {expense, _credit}} =
        Transactions.link_reimbursement_pair(user(), expense.id, credit.id)

      pairs = Transactions.get_reimbursement_pairs(user(), [expense.reimbursement_link_key])

      assert [%{amount: negative}, %{amount: positive}] =
               pairs[expense.reimbursement_link_key]

      assert Decimal.negative?(negative)
      assert Decimal.positive?(positive)
    end

    test "returns an empty map for no keys" do
      assert Transactions.get_reimbursement_pairs(user(), []) == %{}
    end
  end

  describe "month breakdowns exclude reimbursement pairs" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    test "get_month_category_breakdown/2 skips transactions carrying a reimbursement_link_key" do
      checking = account_fixture(%{is_credit_card: false})
      health = category_fixture(%{name: "Saúde", slug: "saude"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-300.00",
        date: ~D[2026-04-10],
        description: "Consulta reembolsada",
        reimbursement_link_key: Ecto.UUID.generate()
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-80.00",
        date: ~D[2026-04-11],
        description: "Farmácia"
      })

      breakdown = Transactions.get_month_category_breakdown(user(), 2026, 4)

      assert [row] = Enum.filter(breakdown, &(&1.category_id == health.id))
      assert Decimal.equal?(row.total, Decimal.new("80.00"))
    end

    test "get_month_income_breakdown/2 skips transactions carrying a reimbursement_link_key" do
      checking = account_fixture(%{is_credit_card: false})
      refunds = category_fixture(%{name: "Reembolsos", slug: "reembolsos"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: refunds.id,
        amount: "300.00",
        date: ~D[2026-04-12],
        description: "Reembolso consulta",
        reimbursement_link_key: Ecto.UUID.generate()
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: refunds.id,
        amount: "45.00",
        date: ~D[2026-04-13],
        description: "Estorno avulso"
      })

      breakdown = Transactions.get_month_income_breakdown(user(), 2026, 4)

      assert [row] = Enum.filter(breakdown, &(&1.category_id == refunds.id))
      assert Decimal.equal?(row.total, Decimal.new("45.00"))
    end

    test "the month breakdowns keep transactions with a reimbursement_status but no reimbursement_link_key" do
      checking = account_fixture(%{is_credit_card: false})
      health = category_fixture(%{name: "Saúde", slug: "saude"})
      refunds = category_fixture(%{name: "Reembolsos", slug: "reembolsos"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-210.00",
        date: ~D[2026-04-14],
        description: "Consulta aguardando reembolso",
        reimbursement_status: "pending",
        reimbursement_link_key: nil
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: refunds.id,
        amount: "60.00",
        date: ~D[2026-04-15],
        description: "Credito aguardando conciliacao",
        reimbursement_status: "pending",
        reimbursement_link_key: nil
      })

      assert [expense_row] =
               Transactions.get_month_category_breakdown(user(), 2026, 4)
               |> Enum.filter(&(&1.category_id == health.id))

      assert Decimal.equal?(expense_row.total, Decimal.new("210.00"))

      assert [income_row] =
               Transactions.get_month_income_breakdown(user(), 2026, 4)
               |> Enum.filter(&(&1.category_id == refunds.id))

      assert Decimal.equal?(income_row.total, Decimal.new("60.00"))
    end

    test "list_all_transactions/1 still returns reimbursement-linked transactions when the exclusion key is absent" do
      checking = account_fixture(%{is_credit_card: false})
      health = category_fixture(%{name: "Saúde", slug: "saude"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-300.00",
        date: ~D[2026-04-10],
        description: "Consulta reembolsada",
        reimbursement_link_key: Ecto.UUID.generate()
      })

      descriptions =
        Transactions.list_all_transactions(user(), %{
          "category_id" => health.id,
          "month" => "4",
          "year" => "2026"
        })
        |> Enum.map(& &1.description)

      assert "Consulta reembolsada" in descriptions
    end

    test "list_all_transactions/1 drops reimbursement-linked transactions when the exclusion key is passed" do
      checking = account_fixture(%{is_credit_card: false})
      health = category_fixture(%{name: "Saúde", slug: "saude"})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-300.00",
        date: ~D[2026-04-10],
        description: "Consulta reembolsada",
        reimbursement_link_key: Ecto.UUID.generate()
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: health.id,
        amount: "-80.00",
        date: ~D[2026-04-11],
        description: "Farmácia"
      })

      descriptions =
        Transactions.list_all_transactions(user(), %{
          "category_id" => health.id,
          "month" => "4",
          "year" => "2026",
          "exclude_reimbursement_linked" => true
        })
        |> Enum.map(& &1.description)

      assert "Farmácia" in descriptions
      refute "Consulta reembolsada" in descriptions
    end
  end

  describe "get_filtered_summary/1 splits cash from card figures" do
    import CashLens.AccountsFixtures
    import CashLens.CategoriesFixtures

    defp market_category, do: category_fixture(%{name: "Mercado CL34", slug: "mercado-cl34"})

    test "puts cash rows and card rows in their own group, summing neither into the other" do
      market = market_category()
      checking = account_fixture(%{is_credit_card: false})
      card = account_fixture(%{is_credit_card: true})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "100.00",
        date: ~D[2026-04-10]
      })

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "-40.00",
        date: ~D[2026-04-11]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "-70.00",
        date: ~D[2026-04-12]
      })

      transaction_fixture(%{
        account_id: card.id,
        category_id: market.id,
        amount: "25.00",
        date: ~D[2026-04-13]
      })

      summary = Transactions.get_filtered_summary(user(), %{"month" => "4", "year" => "2026"})

      assert summary |> Map.keys() |> Enum.sort() == [:cards, :cash]

      assert Decimal.equal?(summary.cash.income, Decimal.new("100.00"))
      assert Decimal.equal?(summary.cash.expenses, Decimal.new("40.00"))
      assert summary.cash.count == 2

      assert Decimal.equal?(summary.cards.income, Decimal.new("25.00"))
      assert Decimal.equal?(summary.cards.expenses, Decimal.new("70.00"))
      assert summary.cards.count == 2

      # No figure is the sum of both sides.
      refute Decimal.equal?(summary.cash.income, Decimal.new("125.00"))
      refute Decimal.equal?(summary.cash.expenses, Decimal.new("110.00"))
      refute Decimal.equal?(summary.cards.income, Decimal.new("125.00"))
      refute Decimal.equal?(summary.cards.expenses, Decimal.new("110.00"))
    end

    test "returns both groups even when one side has no matching rows" do
      market = market_category()
      checking = account_fixture(%{is_credit_card: false})

      transaction_fixture(%{
        account_id: checking.id,
        category_id: market.id,
        amount: "-15.00",
        date: ~D[2026-05-10]
      })

      summary = Transactions.get_filtered_summary(user(), %{"month" => "5", "year" => "2026"})

      assert summary.cash.count == 1
      assert Decimal.equal?(summary.cash.expenses, Decimal.new("15.00"))
      assert Decimal.equal?(summary.cash.income, Decimal.new("0"))

      assert summary.cards.count == 0
      assert Decimal.equal?(summary.cards.income, Decimal.new("0"))
      assert Decimal.equal?(summary.cards.expenses, Decimal.new("0"))
    end
  end

  describe "create_transaction/2 with allow_duplicate" do
    import CashLens.AccountsFixtures

    defp charge_attrs(account) do
      %{
        account_id: account.id,
        date: ~D[2026-09-08],
        description: "AMAZONMKTPLC*BKSCOMERC",
        amount: Decimal.new("-245.90")
      }
    end

    test "a confirmed duplicate is written instead of being swallowed" do
      # Paying the same bill twice by mistake is a real pair of charges. Without
      # this the only way to record the second was to falsify its date, which
      # breaks reconciliation against the statement it belongs to.
      account = AccountsFixtures.account_fixture()
      attrs = charge_attrs(account)

      assert {:ok, %Transaction{} = first} = Transactions.create_transaction(user(), attrs)
      assert {:ok, :duplicate} = Transactions.create_transaction(user(), attrs)

      assert {:ok, %Transaction{} = second} =
               Transactions.create_transaction(user(), attrs, allow_duplicate: true)

      refute second.id == first.id
      assert second.date == first.date
      assert second.description == first.description
      assert Decimal.equal?(second.amount, first.amount)
      refute second.fingerprint == first.fingerprint
      assert second.dedup_key == first.dedup_key
    end

    test "a third identical charge still finds a free index" do
      account = AccountsFixtures.account_fixture()
      attrs = charge_attrs(account)

      {:ok, _} = Transactions.create_transaction(user(), attrs)
      {:ok, _} = Transactions.create_transaction(user(), attrs, allow_duplicate: true)

      assert {:ok, %Transaction{}} =
               Transactions.create_transaction(user(), attrs, allow_duplicate: true)

      assert Repo.aggregate(
               from(t in Transaction, where: t.account_id == ^account.id),
               :count
             ) == 3
    end

    test "the freed index of a deleted middle row is reused" do
      # Counting rows would skip past the gap and land on an index already in
      # use, failing the unique constraint. The search walks upward instead.
      account = AccountsFixtures.account_fixture()
      attrs = charge_attrs(account)

      {:ok, first} = Transactions.create_transaction(user(), attrs)
      {:ok, _second} = Transactions.create_transaction(user(), attrs, allow_duplicate: true)

      Repo.delete!(first)

      assert {:ok, %Transaction{} = replacement} =
               Transactions.create_transaction(user(), attrs, allow_duplicate: true)

      assert replacement.fingerprint == first.fingerprint
    end

    test "without the flag the behaviour is unchanged" do
      account = AccountsFixtures.account_fixture()
      attrs = charge_attrs(account)

      {:ok, _} = Transactions.create_transaction(user(), attrs)

      assert {:ok, :duplicate} = Transactions.create_transaction(user(), attrs)

      assert {:ok, :duplicate} =
               Transactions.create_transaction(user(), attrs, allow_duplicate: false)
    end
  end

  describe "duplicate_of/1" do
    import CashLens.AccountsFixtures

    test "finds the charge a manual create is about to repeat" do
      account = AccountsFixtures.account_fixture()

      attrs = %{
        account_id: account.id,
        date: ~D[2026-09-08],
        description: "AMAZONMKTPLC*BKSCOMERC",
        amount: Decimal.new("-245.90")
      }

      {:ok, existing} = Transactions.create_transaction(user(), attrs)

      assert %Transaction{id: id} = Transactions.duplicate_of(user(), attrs)
      assert id == existing.id
    end

    test "a differing amount is not the same charge" do
      account = AccountsFixtures.account_fixture()

      attrs = %{
        account_id: account.id,
        date: ~D[2026-09-08],
        description: "AMAZONMKTPLC*BKSCOMERC",
        amount: Decimal.new("-245.90")
      }

      {:ok, _} = Transactions.create_transaction(user(), attrs)

      assert Transactions.duplicate_of(user(), %{attrs | amount: Decimal.new("-245.91")}) == nil
    end

    test "incomplete attrs have no identity, so nothing is claimed" do
      assert Transactions.duplicate_of(user(), %{description: "SEM CONTA"}) == nil
    end
  end

  describe "spend_rate/4" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp spent(date, amount) do
      transaction_fixture(%{account_id: account_fixture().id, date: date, amount: amount})
    end

    test "divides the month by the days the ledger covers, not by its length" do
      # 900 spent, the statement reaching the 9th. Dividing by the month's 31
      # days would read it as 29/day -- a quiet month, right up to the
      # overdraft.
      spent(~D[2026-10-03], "-400.00")
      spent(~D[2026-10-09], "-500.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("900.00"), ~D[2026-10-09])

      assert Decimal.equal?(rate.per_day, Decimal.new("100"))
    end

    # Dividing by the calendar turns an unimported week into good news. On
    # 11/10/2026 the real statement stopped at the 5th: six days of spending
    # spread over eleven read as 771/day, 30% under the average, when the
    # covered days gave 1696 -- a quarter above it. The arrow pointed the wrong
    # way for want of data.
    test "a stale statement does not stretch the month and flatter the rate" do
      spent(~D[2026-10-05], "-900.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("900.00"), ~D[2026-10-11])

      # 900 over the five covered days, not over the eleven on the calendar.
      assert Decimal.equal?(rate.per_day, Decimal.new("180"))
    end

    # A transfer is not spending, but it is proof the statement was imported
    # that far -- which is the only thing the divisor asks.
    test "any movement marks how far the ledger reaches, transfers included" do
      account = account_fixture()
      transfer = CashLens.CategoriesFixtures.category_fixture(%{slug: "transfer"})
      spent(~D[2026-10-02], "-600.00")

      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-10-06],
        amount: "-5000.00",
        category_id: transfer.id
      })

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("600.00"), ~D[2026-10-11])

      # Six covered days because of the transfer, not two because of the spend.
      assert Decimal.equal?(rate.per_day, Decimal.new("100"))
    end

    # Month-end "Rendimento" rows are posted ahead of time. A plain max(date)
    # would read 31/10 as the ledger's reach on the 11th and halve the rate.
    test "a row dated in the future does not stretch the covered days" do
      spent(~D[2026-10-05], "-900.00")
      spent(~D[2026-10-31], "-10.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("900.00"), ~D[2026-10-11])

      assert Decimal.equal?(rate.per_day, Decimal.new("180"))
    end

    test "with nothing imported this month the rate is the month's whole spending" do
      spent(~D[2026-09-20], "-3000.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("450.00"), ~D[2026-10-11])

      assert Decimal.equal?(rate.per_day, Decimal.new("450"))
    end

    test "a month already closed is divided by all of its days" do
      rate =
        Transactions.spend_rate(user(), ~D[2026-09-01], Decimal.new("900.00"), ~D[2026-10-09])

      assert Decimal.equal?(rate.per_day, Decimal.new("30"))
    end

    test "compares against whole months only, and says how far off it is" do
      # August: 31 days, 3100 spent. September: 30 days, 3000 spent. Baseline
      # is 6100/61 = 100/day. October is running at 150/day: half as fast again.
      spent(~D[2026-08-10], "-3100.00")
      spent(~D[2026-09-10], "-3000.00")
      spent(~D[2026-10-10], "-1500.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("1500.00"), ~D[2026-10-10])

      assert Decimal.equal?(rate.average, Decimal.new("100"))
      assert Decimal.equal?(Decimal.round(rate.delta, 2), Decimal.new("0.50"))
      assert rate.months == 2
    end

    test "the month being measured never counts towards its own baseline" do
      # Without the cutoff, October's own spending would be averaged into the
      # average October is compared against, and a spike would partly hide
      # itself.
      spent(~D[2026-09-10], "-3000.00")
      spent(~D[2026-10-05], "-9000.00")

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("9000.00"), ~D[2026-10-10])

      assert Decimal.equal?(rate.average, Decimal.new("100"))
      assert rate.months == 1
    end

    test "transfers and initial values are not money leaving, and do not count" do
      account = account_fixture()
      other = account_fixture(%{name: "Poupança"})
      transfer = CashLens.CategoriesFixtures.category_fixture(%{slug: "transfer"})

      transaction_fixture(%{
        account_id: account.id,
        date: ~D[2026-09-10],
        amount: "-5000.00",
        category_id: transfer.id
      })

      transaction_fixture(%{account_id: other.id, date: ~D[2026-09-11], amount: "-3000.00"})

      rate = Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("0"), ~D[2026-10-10])

      # 3000 over September's 30 days. The 5000 that only moved between the
      # user's own accounts is not spending.
      assert Decimal.equal?(rate.average, Decimal.new("100"))
    end

    test "the baseline is the most recent months, not the oldest ones on file" do
      # Nine months of history for a six-month baseline. March was an outlier
      # at 1000/day; everything since has run at 100. A baseline that reached
      # for the oldest months instead of the newest would read the quiet month
      # as a 60% improvement on a spike that is half a year gone.
      spent(~D[2026-03-15], "-31000.00")

      for {month, amount} <- [
            {4, "-3000.00"},
            {5, "-3100.00"},
            {6, "-3000.00"},
            {7, "-3100.00"},
            {8, "-3100.00"},
            {9, "-3000.00"}
          ] do
        spent(Date.new!(2026, month, 15), amount)
      end

      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("1000.00"), ~D[2026-10-10])

      assert rate.months == 6
      assert Decimal.equal?(rate.average, Decimal.new("100"))
    end

    test "with no history there is no comparison to make" do
      rate =
        Transactions.spend_rate(user(), ~D[2026-10-01], Decimal.new("900.00"), ~D[2026-10-10])

      assert rate.delta == nil
      assert rate.months == 0
      assert Decimal.equal?(rate.average, Decimal.new("0"))
    end
  end
end
