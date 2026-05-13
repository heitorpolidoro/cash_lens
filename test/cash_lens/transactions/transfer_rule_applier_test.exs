defmodule CashLens.Transactions.TransferRuleApplierTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferRule
  alias CashLens.Transactions.TransferRuleApplier

  defp create_transfer_category do
    category_fixture(%{name: "Transfer", slug: "transfer"})
  end

  defp create_rule(source_id, dest_id, patterns) do
    {:ok, rule} =
      Repo.insert(%TransferRule{
        description_patterns: patterns,
        source_account_id: source_id,
        destination_account_id: dest_id
      })

    rule
  end

  # Insert a transaction directly (bypassing context hooks like maybe_apply_rule)
  # so we can test apply_rules in isolation.
  defp insert_raw_transaction(attrs) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert!()
  end

  describe "apply_rules/1" do
    test "creates a mirror transaction when a rule matches" do
      transfer_cat = create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Salary Payment",
          amount: "1000.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])

      assert length(mirrors) == 1
      [mirror] = mirrors
      assert mirror.account_id == destination.id
      assert mirror.description == "Salary Payment"
      assert Decimal.equal?(mirror.amount, Decimal.new("-1000.00"))
      assert mirror.date == ~D[2026-01-15]
      assert mirror.category_id == transfer_cat.id

      # Source transaction should have transfer category and a transfer_key
      updated_tx = Repo.get!(Transaction, tx.id)
      assert updated_tx.category_id == transfer_cat.id
      assert updated_tx.transfer_key != nil

      # Mirror should share the same transfer_key
      updated_mirror = Repo.get!(Transaction, mirror.id)
      assert updated_mirror.transfer_key == updated_tx.transfer_key
    end

    test "matching is case-insensitive" do
      create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["SALARY PAYMENT"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "salary payment",
          amount: "500.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])
      assert length(mirrors) == 1
    end

    test "does not create mirror when description does not match" do
      create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "some other transaction",
          amount: "200.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])
      assert mirrors == []
    end

    test "links source to existing unlinked mirror in destination account" do
      create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      # Pre-insert the mirror transaction in the destination account without a transfer_key
      existing_mirror =
        insert_raw_transaction(%{
          account_id: destination.id,
          description: "Salary Payment",
          amount: "-1000.00",
          date: ~D[2026-01-15]
        })

      assert is_nil(existing_mirror.transfer_key)

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Salary Payment",
          amount: "1000.00",
          date: ~D[2026-01-15]
        })

      # apply_rules should find the existing mirror and link both — no new transaction created
      result = TransferRuleApplier.apply_rules([tx])
      assert result == []

      updated_tx = Repo.get!(Transaction, tx.id)
      updated_mirror = Repo.get!(Transaction, existing_mirror.id)

      refute is_nil(updated_tx.transfer_key)
      assert updated_tx.transfer_key == updated_mirror.transfer_key
    end

    test "idempotency: does not create mirror if one already exists" do
      create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Salary Payment",
          amount: "1000.00",
          date: ~D[2026-01-15]
        })

      # First application creates the mirror
      mirrors1 = TransferRuleApplier.apply_rules([tx])
      assert length(mirrors1) == 1
      [mirror] = mirrors1

      # Second application should be idempotent
      mirrors2 = TransferRuleApplier.apply_rules([tx])
      assert mirrors2 == []

      # Both source and mirror should still share the same transfer_key
      updated_tx = Repo.get!(Transaction, tx.id)
      updated_mirror = Repo.get!(Transaction, mirror.id)
      assert updated_tx.transfer_key != nil
      assert updated_tx.transfer_key == updated_mirror.transfer_key
    end

    test "returns empty list and logs warning when transfer category does not exist" do
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Salary Payment",
          amount: "1000.00",
          date: ~D[2026-01-15]
        })

      assert ExUnit.CaptureLog.capture_log(fn ->
               mirrors = TransferRuleApplier.apply_rules([tx])
               assert mirrors == []
             end) =~ "TransferRuleApplier: 'transfer' category not found"
    end

    test "handles empty list of transactions" do
      create_transfer_category()
      assert TransferRuleApplier.apply_rules([]) == []
    end

    test "returns [] and logs warning when mirror insert fails" do
      import Mox

      create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["salary payment"])

      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Salary Payment",
          amount: "1000.00",
          date: ~D[2026-01-15]
        })

      Application.put_env(:cash_lens, :transfer_rule_repo, CashLens.Transactions.RepoMock)

      expect(CashLens.Transactions.RepoMock, :insert, fn _changeset, _opts ->
        {:error, :simulated_db_failure}
      end)

      try do
        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert TransferRuleApplier.apply_rules([tx]) == []
               end) =~ "TransferRuleApplier: Failed to insert mirror transaction"
      after
        Application.delete_env(:cash_lens, :transfer_rule_repo)
      end
    end

    test "only matches rules for the transaction's source account" do
      create_transfer_category()
      source_a = account_fixture()
      source_b = account_fixture()
      destination = account_fixture()
      create_rule(source_a.id, destination.id, ["matched description"])

      tx =
        insert_raw_transaction(%{
          account_id: source_b.id,
          description: "matched description",
          amount: "300.00",
          date: ~D[2026-01-15]
        })

      mirrors = TransferRuleApplier.apply_rules([tx])
      assert mirrors == []
    end
  end

  describe "maybe_apply_rule/1" do
    test "creates a mirror transaction when a rule matches" do
      transfer_cat = create_transfer_category()
      source = account_fixture()
      destination = account_fixture()
      create_rule(source.id, destination.id, ["bill payment"])

      # Insert the transaction bypassing context to control when maybe_apply_rule is called
      tx =
        insert_raw_transaction(%{
          account_id: source.id,
          description: "Bill Payment",
          amount: "250.00",
          date: ~D[2026-02-10]
        })

      mirrors = TransferRuleApplier.maybe_apply_rule(tx)

      assert length(mirrors) == 1
      [mirror] = mirrors
      assert mirror.account_id == destination.id
      assert mirror.category_id == transfer_cat.id

      # Both source and mirror should share the same non-nil transfer_key
      updated_tx = Repo.get!(Transaction, tx.id)
      updated_mirror = Repo.get!(Transaction, mirror.id)
      assert updated_tx.transfer_key != nil
      assert updated_tx.transfer_key == updated_mirror.transfer_key
    end

    test "returns empty list when no rule matches" do
      create_transfer_category()
      source = account_fixture()

      {:ok, tx} =
        Transactions.create_transaction(%{
          account_id: source.id,
          description: "Unmatched description",
          amount: "100.00",
          date: ~D[2026-02-10]
        })

      assert TransferRuleApplier.maybe_apply_rule(tx) == []
    end
  end
end
