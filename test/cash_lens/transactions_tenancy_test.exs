defmodule CashLens.TransactionsTenancyTest do
  @moduledoc """
  User B never reads, changes or links user A's transactions, transfer rules,
  bulk ignore patterns or rejected reimbursement pairs.

  Calls made for B run with the process pinned to A on purpose: row-level
  security would then let A's rows through, so what keeps them out of B's
  results is only the application-level `Ownership.scope/2` filter.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Tenancy
  alias CashLens.Transactions
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.BulkIgnorePattern
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.RejectedReimbursementPair
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRule
  alias CashLens.Transactions.TransferRuleApplier

  @date ~D[2026-03-10]

  setup do
    %{a: a, b: b} = cross_tenant()

    Tenancy.acting_as(a, fn ->
      acct1 = account_fixture(%{user: a, name: "A checking"})
      acct2 = account_fixture(%{user: a, name: "A savings"})
      transfer = category_fixture(%{user: a, name: "Transfer"})
      groceries = category_fixture(%{user: a, name: "Groceries", keywords: "netflix"})

      tx = fn attrs ->
        transaction_fixture(
          Map.merge(%{user: a, date: @date, description: "A #{System.unique_integer()}"}, attrs)
        )
      end

      # An unmatched transfer pair the matcher/suggestions would pick up.
      out = tx.(%{account_id: acct1.id, amount: "-50.00", category_id: transfer.id})
      inc = tx.(%{account_id: acct2.id, amount: "50.00"})

      # A linked transfer pair.
      linked_out = tx.(%{account_id: acct1.id, amount: "-70.00", category_id: transfer.id})
      linked_in = tx.(%{account_id: acct2.id, amount: "70.00", category_id: transfer.id})
      {:ok, transfer_key} = Transactions.link_transfer_pair(a, linked_out.id, linked_in.id)

      # A reimbursement suggestion, a linked reimbursement pair and a rejected one.
      refund_out =
        tx.(%{account_id: acct1.id, amount: "-30.00", reimbursement_status: "pending"})

      refund_in = tx.(%{account_id: acct2.id, amount: "30.00"})
      paid_out = tx.(%{account_id: acct1.id, amount: "-20.00", reimbursement_status: "pending"})
      paid_in = tx.(%{account_id: acct2.id, amount: "20.00"})
      {:ok, _} = Transactions.link_reimbursement_pair(a, paid_out.id, paid_in.id)
      paid_out = Transactions.get_transaction!(a, paid_out.id)

      rej_a = tx.(%{account_id: acct1.id, amount: "-11.00"})
      rej_b = tx.(%{account_id: acct2.id, amount: "11.00"})
      {:ok, rejected} = Transactions.reject_reimbursement_pair(a, rej_a.id, rej_b.id)

      rule = transfer_rule_fixture(%{user: a})
      pattern = insert_bulk_ignore_pattern(%{user: a, pattern: "tenancy-a-pattern"})

      %{
        a: a,
        b: b,
        acct1: acct1,
        acct2: acct2,
        transfer: transfer,
        groceries: groceries,
        out: out,
        inc: inc,
        linked_out: linked_out,
        transfer_key: transfer_key,
        refund_out: refund_out,
        refund_in: refund_in,
        paid_out: paid_out,
        rejected: rejected,
        rule: rule,
        pattern: pattern
      }
    end)
  end

  # Runs `fun` as the foreign process: pinned to A while the calls name B.
  defp as_a(ctx, fun), do: Tenancy.acting_as(ctx.a, fun)

  # A's persisted rows, read as A.
  defp snapshot(ctx) do
    as_a(ctx, fn ->
      {Repo.all(from t in Transaction, order_by: t.id), Repo.all(TransferRule),
       Repo.all(BulkIgnorePattern), Repo.all(RejectedReimbursementPair)}
    end)
  end

  describe "user B cannot read user A's rows" do
    test "transaction lists, counts and summaries come back empty", ctx do
      %{b: b, acct1: acct1, transfer: transfer} = ctx

      as_a(ctx, fn ->
        assert Transactions.list_transactions(b) == []
        assert Transactions.list_transactions(b, %{"account_id" => acct1.id}) == []
        assert Transactions.list_transactions(b, %{"category_id" => transfer.id}) == []
        assert Transactions.list_all_transactions(b) == []
        assert Transactions.list_all_transactions(b, %{"cash_accounts_only" => true}) == []
        assert Transactions.list_recent_transactions(b) == []
        assert Transactions.list_transactions_by_description(b, "A") == []
        assert Transactions.count_transactions(b) == 0
        assert Transactions.count_pending_transactions(b) == 0
        assert Transactions.get_filtered_summary(b) == Transactions.empty_filtered_summary()
        assert Transactions.list_reimbursement_credit_candidates(b) == []

        assert Transactions.statement_health(b) == %{
                 uncategorized_count: 0,
                 reimbursements_receivable_count: 0,
                 reimbursements_receivable_total: Decimal.new("0"),
                 unmatched_transfers_count: 0
               }
      end)
    end

    test "a monthly total for B never includes A's transactions in the same month", ctx do
      %{a: a, b: b} = ctx

      as_a(ctx, fn ->
        assert Decimal.compare(Transactions.get_monthly_summary(a, @date).expenses, 0) == :gt

        assert %{income: income, expenses: expenses} = Transactions.get_monthly_summary(b, @date)
        assert Decimal.eq?(income, 0)
        assert Decimal.eq?(expenses, 0)

        assert Transactions.get_historical_summary(b) == []
        assert Transactions.get_historical_category_summary(b) == []
        assert Transactions.get_month_category_breakdown(b, 2026, 3) == []
        assert Transactions.get_month_income_breakdown(b, 2026, 3) == []
        assert Transactions.summary_excluded_category_ids(b) == []
      end)
    end

    test "dates and single rows are not visible", ctx do
      %{a: a, b: b, acct1: acct1, out: out} = ctx

      as_a(ctx, fn ->
        assert Transactions.get_latest_transaction_date(a) == @date
        assert Transactions.get_latest_transaction_date(b) == nil
        assert Transactions.latest_transaction_date(b, acct1.id) == nil
        assert Transactions.latest_transaction_date_between(b, acct1.id, @date, @date) == nil
        assert Transactions.latest_transaction_dates(b) == %{}
        assert Transactions.get_transaction(b, out.id) == nil
        assert_raise Ecto.NoResultsError, fn -> Transactions.get_transaction!(b, out.id) end

        assert Transactions.duplicate_of(b, %{
                 "account_id" => acct1.id,
                 "date" => Date.to_iso8601(@date),
                 "description" => out.description,
                 "amount" => "-50.00"
               }) == nil

        assert Transactions.suggest_installment_link(b, out) == nil
      end)
    end

    test "transfer and reimbursement lists and pairs are empty", ctx do
      %{b: b, out: out, transfer_key: key, paid_out: paid_out} = ctx

      as_a(ctx, fn ->
        assert Transactions.list_transfer_suggestions(b) == []
        assert Transactions.list_unmatched_transfers_without_suggestion(b) == []
        assert Transactions.list_transfer_link_candidates(b, out) == []
        assert Transactions.list_linked_transfer_pairs(b) == []
        assert Transactions.get_transfer_pairs(b, [key]) == %{}
        assert Transactions.list_reimbursement_suggestions(b) == []
        assert Transactions.list_unmatched_reimbursements_without_suggestion(b) == []
        assert Transactions.list_linked_reimbursement_pairs(b) == []

        assert Transactions.get_reimbursement_pairs(b, [paid_out.reimbursement_link_key]) ==
                 %{}
      end)
    end

    test "A still sees the same data", ctx do
      %{a: a, out: out, transfer_key: key} = ctx

      as_a(ctx, fn ->
        assert Enum.any?(Transactions.list_transactions(a), &(&1.id == out.id))
        assert Transactions.list_transfer_suggestions(a) != []
        assert [{_, _}] = Transactions.list_linked_transfer_pairs(a)
        assert Map.has_key?(Transactions.get_transfer_pairs(a, [key]), key)
        assert Transactions.list_reimbursement_suggestions(a) != []
        assert [{_, _}] = Transactions.list_linked_reimbursement_pairs(a)
      end)
    end

    test "transfer rules, ignore patterns and rejected pairs are not visible", ctx do
      %{b: b, rule: rule, pattern: pattern} = ctx

      as_a(ctx, fn ->
        assert Transactions.list_transfer_rules(b) == []
        assert Transactions.list_bulk_ignore_patterns(b) == []

        assert_raise Ecto.NoResultsError, fn -> Transactions.get_transfer_rule!(b, rule.id) end

        assert_raise Ecto.NoResultsError, fn ->
          Transactions.get_bulk_ignore_pattern!(b, pattern.id)
        end

        # A rejected pair hides a suggestion for A only; B has nothing to hide.
        assert Transactions.list_reimbursement_suggestions(b) == []
      end)
    end
  end

  describe "user B cannot change user A's rows" do
    test "update, delete and quick categorize answer not_found and change nothing", ctx do
      %{b: b, out: out, groceries: groceries} = ctx
      before = snapshot(ctx)

      as_a(ctx, fn ->
        assert {:error, :not_found} = Transactions.update_transaction(b, out, %{notes: "hijack"})
        assert {:error, :not_found} = Transactions.delete_transaction(b, out)

        assert {:error, :not_found} =
                 Transactions.update_transaction_category(b, out.id, groceries.id)

        assert {:error, :not_found} =
                 Transactions.update_transaction_category(b, out.id, nil)
      end)

      assert snapshot(ctx) == before
    end

    test "transfer rule and ignore pattern updates and deletes answer not_found", ctx do
      %{b: b, rule: rule, pattern: pattern} = ctx
      before = snapshot(ctx)

      as_a(ctx, fn ->
        assert {:error, :not_found} =
                 Transactions.update_transfer_rule(b, rule, %{label: "hijacked"})

        assert {:error, :not_found} = Transactions.delete_transfer_rule(b, rule)

        assert {:error, :not_found} =
                 Transactions.update_bulk_ignore_pattern(b, pattern, %{pattern: "hijacked"})

        assert {:error, :not_found} = Transactions.delete_bulk_ignore_pattern(b, pattern)
      end)

      assert snapshot(ctx) == before
    end

    test "link, unlink and reject functions answer not_found and change nothing", ctx do
      %{b: b, out: out, inc: inc, transfer_key: key, paid_out: paid_out} = ctx
      %{refund_out: refund_out, refund_in: refund_in, acct2: acct2} = ctx
      before = snapshot(ctx)

      as_a(ctx, fn ->
        assert {:error, :not_found} = Transactions.link_transfer_pair(b, out.id, inc.id)
        assert {:error, :not_found} = Transactions.unlink_transfer_pair(b, key)

        assert {:error, :not_found} =
                 Transactions.link_reimbursement_pair(b, refund_out.id, refund_in.id)

        assert {:error, :not_found} =
                 Transactions.link_reimbursement_group(b, [refund_out.id], [refund_in.id], nil)

        assert {:error, :not_found} =
                 Transactions.unlink_reimbursement_by_key(b, paid_out.reimbursement_link_key)

        assert {:error, :not_found} =
                 Transactions.reject_reimbursement_pair(b, refund_out.id, refund_in.id)

        assert {:error, :not_found} = Transactions.create_mirror_transaction(b, out.id, acct2.id)
      end)

      assert snapshot(ctx) == before
    end

    test "a mix of owned and foreign ids links nothing", ctx do
      %{b: b, refund_out: refund_out} = ctx
      before = snapshot(ctx)

      mine =
        Tenancy.acting_as(b, fn ->
          transaction_fixture(%{user: b, amount: "30.00", date: @date})
        end)

      Tenancy.acting_as(b, fn ->
        assert {:error, :not_found} =
                 Transactions.link_reimbursement_group(b, [refund_out.id], [mine.id], nil)

        assert {:error, :not_found} = Transactions.link_transfer_pair(b, refund_out.id, mine.id)
      end)

      assert snapshot(ctx) == before
    end

    test "bulk operations only touch the caller's rows", ctx do
      %{a: a, b: b} = ctx
      before = snapshot(ctx)

      Tenancy.acting_as(b, fn ->
        # B has no transactions: both bulk reapplies and delete_all see nothing of A's.
        assert :ok = Transactions.reapply_auto_categorization(b)
        assert {:ok, 0} = Transactions.reapply_transfer_rules(b)
        assert {0, nil} = Transactions.delete_all_transactions(b)
      end)

      as_a(ctx, fn ->
        assert {0, nil} = Transactions.delete_all_transactions(b)
        assert :ok = Transactions.reapply_auto_categorization(b)
        assert {:ok, 0} = Transactions.reapply_transfer_rules(b)
      end)

      assert snapshot(ctx) == before
      assert Tenancy.acting_as(a, fn -> Transactions.list_transactions(a) end) != []
    end
  end

  describe "foreign keys" do
    test "creating a transaction on another user's account is a changeset error", ctx do
      %{b: b, acct1: acct1} = ctx
      before = snapshot(ctx)

      Tenancy.acting_as(b, fn ->
        assert {:error, changeset} =
                 Transactions.create_transaction(b, %{
                   account_id: acct1.id,
                   amount: "10",
                   date: @date,
                   description: "forged account"
                 })

        assert %{account_id: ["does not exist"]} = errors_on(changeset)

        assert Repo.aggregate(
                 from(t in Transaction, where: t.description == "forged account"),
                 :count
               ) == 0
      end)

      assert snapshot(ctx) == before
    end

    test "creating a transaction with another user's category is a changeset error", ctx do
      %{b: b, groceries: groceries} = ctx

      Tenancy.acting_as(b, fn ->
        own = account_fixture(%{user: b})

        assert {:error, changeset} =
                 Transactions.create_transaction(b, %{
                   account_id: own.id,
                   category_id: groceries.id,
                   amount: "10",
                   date: @date,
                   description: "forged category"
                 })

        assert %{category_id: ["does not exist"]} = errors_on(changeset)

        assert Repo.aggregate(
                 from(t in Transaction, where: t.description == "forged category"),
                 :count
               ) == 0
      end)
    end

    test "a user_id in the attributes is ignored", ctx do
      %{a: a, b: b} = ctx

      Tenancy.acting_as(b, fn ->
        own = account_fixture(%{user: b})

        assert {:ok, tx} =
                 Transactions.create_transaction(b, %{
                   "user_id" => a.id,
                   "account_id" => own.id,
                   "amount" => "10",
                   "date" => @date,
                   "description" => "owner override"
                 })

        assert tx.user_id == b.id
      end)
    end

    test "a transfer rule with another user's account or category fields is rejected", ctx do
      %{b: b, acct1: acct1, acct2: acct2} = ctx

      Tenancy.acting_as(b, fn ->
        assert {:error, changeset} =
                 Transactions.create_transfer_rule(b, %{
                   label: "forged",
                   description_patterns: ["x"],
                   source_account_id: acct1.id,
                   destination_account_id: acct2.id
                 })

        assert %{
                 source_account_id: ["does not exist"],
                 destination_account_id: ["does not exist"]
               } =
                 errors_on(changeset)
      end)
    end

    test "a rejected pair changeset flags transaction ids owned by someone else", ctx do
      %{b: b, out: out, inc: inc} = ctx

      Tenancy.acting_as(b, fn ->
        changeset =
          RejectedReimbursementPair.changeset(%RejectedReimbursementPair{user_id: b.id}, %{
            transaction_a_id: out.id,
            transaction_b_id: inc.id
          })

        refute changeset.valid?
        assert %{transaction_a_id: ["does not exist"]} = errors_on(changeset)
      end)
    end

    test "quick categorize with another user's category is a changeset error", ctx do
      %{b: b, groceries: groceries} = ctx

      Tenancy.acting_as(b, fn ->
        own = transaction_fixture(%{user: b, date: @date})

        assert {:error, changeset} =
                 Transactions.update_transaction_category(b, own.id, groceries.id)

        assert %{category_id: ["does not exist"]} = errors_on(changeset)
        assert Transactions.get_transaction!(b, own.id).category_id == nil
      end)
    end

    test "a mirror transaction needs the destination account to be the user's", ctx do
      %{b: b, acct1: acct1} = ctx

      Tenancy.acting_as(b, fn ->
        own = transaction_fixture(%{user: b, amount: "-5.00", date: @date})

        assert {:error, :not_found} = Transactions.create_mirror_transaction(b, own.id, acct1.id)
        assert Repo.aggregate(Transaction, :count) == 1
      end)
    end
  end

  describe "helper modules" do
    test "TransferMatcher never links A's twin to B's transaction", ctx do
      %{a: a, b: b, out: out, inc: inc} = ctx

      b_tx =
        Tenancy.acting_as(b, fn ->
          b_category = category_fixture(%{user: b, name: "B misc"})

          transaction_fixture(%{
            user: b,
            amount: "-50.00",
            date: @date,
            category_id: b_category.id
          })
        end)

      as_a(ctx, fn ->
        # Same date and opposite amount as A's unmatched income, and A's "transfer"
        # category is not B's to use.
        assert :not_a_transfer = TransferMatcher.match_transfer(b, b_tx)
        assert is_nil(TransferMatcher.match_transfers(b, [b_tx]))
        # A transaction of A handed to B's matcher is ignored outright.
        assert :no_match = TransferMatcher.match_transfer(b, out)
        assert is_nil(TransferMatcher.match_transfers(b, [out]))
      end)

      as_a(ctx, fn ->
        assert Transactions.get_transaction!(a, inc.id).transfer_key == nil
        assert Transactions.get_transaction!(a, out.id).transfer_key == nil
      end)
    end

    test "TransferRuleApplier applies none of A's rules for B and touches nothing of A's", ctx do
      %{a: a, b: b, rule: rule} = ctx

      a_tx =
        Tenancy.acting_as(a, fn ->
          transaction_fixture(%{
            user: a,
            account_id: rule.source_account_id,
            amount: "-9.00",
            date: @date,
            description: Enum.at(rule.description_patterns, 0)
          })
        end)

      before = snapshot(ctx)

      as_a(ctx, fn ->
        assert [] = TransferRuleApplier.maybe_apply_rule(b, a_tx)
        assert [] = TransferRuleApplier.apply_rules(b, [a_tx])
      end)

      assert snapshot(ctx) == before
    end

    test "AutoCategorizer ignores A's keywords and A's transfer rules for B", ctx do
      %{b: b, rule: rule, groceries: groceries} = ctx

      as_a(ctx, fn ->
        result = AutoCategorizer.categorize(b, %{description: "NETFLIX 123"})
        refute Map.get(result, :category_id)
        refute Map.get(result, :category_id) == groceries.id

        result =
          AutoCategorizer.categorize(b, %{
            description: Enum.at(rule.description_patterns, 0),
            account_id: rule.source_account_id
          })

        refute Map.get(result, :category_id)
      end)
    end

    test "CategorySuggester never suggests from A's history for B", ctx do
      %{a: a, b: b, acct1: acct1, groceries: groceries} = ctx

      Tenancy.acting_as(a, fn ->
        transaction_fixture(%{
          user: a,
          account_id: acct1.id,
          category_id: groceries.id,
          description: "Padaria Estrela",
          date: @date
        })
      end)

      b_tx =
        Tenancy.acting_as(b, fn ->
          transaction_fixture(%{user: b, description: "Padaria Estrela", date: @date})
        end)

      as_a(ctx, fn ->
        assert CategorySuggester.suggest_for(b, [b_tx]) == %{}
        assert [%{suggested_category: nil}] = CategorySuggester.annotate(b, [b_tx])
      end)

      suggestion = Tenancy.acting_as(a, fn -> CategorySuggester.suggest_for(a, [b_tx]) end)
      assert suggestion[b_tx.id].category_id == groceries.id
    end
  end
end
