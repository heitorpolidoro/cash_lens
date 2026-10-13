defmodule CashLens.Transactions.TransferRuleContextTest do
  use CashLens.DataCase, async: false

  defp user, do: CashLens.Repo.get!(CashLens.Users.User, CashLens.Repo.current_user_id())

  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions
  alias CashLens.Transactions.TransferRule

  setup do
    source = account_fixture()
    destination = account_fixture()
    %{source: source, destination: destination}
  end

  describe "list_transfer_rules/0" do
    test "returns all rules with preloaded associations", %{
      source: source,
      destination: destination
    } do
      _rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      rules = Transactions.list_transfer_rules(user())
      refute rules == []
      rule = hd(rules)
      assert %TransferRule{} = rule
      assert rule.source_account != nil
      assert rule.destination_account != nil
    end
  end

  describe "get_transfer_rule!/1" do
    test "returns the rule with preloaded associations", %{
      source: source,
      destination: destination
    } do
      rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      fetched = Transactions.get_transfer_rule!(user(), rule.id)
      assert fetched.id == rule.id
      assert fetched.source_account.id == source.id
      assert fetched.destination_account.id == destination.id
    end

    test "raises when rule not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Transactions.get_transfer_rule!(user(), Ecto.UUID.generate())
      end
    end
  end

  describe "create_transfer_rule/1" do
    test "creates a rule with valid attrs", %{source: source, destination: destination} do
      attrs = %{
        label: "My Rule",
        description_patterns: ["TEST PATTERN"],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      assert {:ok, %TransferRule{} = rule} = Transactions.create_transfer_rule(user(), attrs)
      assert rule.label == "My Rule"
      assert rule.description_patterns == ["TEST PATTERN"]
      assert rule.source_account_id == source.id
      assert rule.destination_account_id == destination.id
    end

    test "returns error changeset with invalid attrs" do
      assert {:error, changeset} = Transactions.create_transfer_rule(user(), %{})

      assert %{description_patterns: _, source_account_id: _, destination_account_id: _} =
               errors_on(changeset)
    end

    test "returns error when source equals destination", %{source: source} do
      attrs = %{
        description_patterns: ["PAY"],
        source_account_id: source.id,
        destination_account_id: source.id
      }

      assert {:error, changeset} = Transactions.create_transfer_rule(user(), attrs)
      assert %{destination_account_id: [_]} = errors_on(changeset)
    end
  end

  describe "update_transfer_rule/2" do
    test "updates a rule with valid attrs", %{source: source, destination: destination} do
      rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      assert {:ok, updated} =
               Transactions.update_transfer_rule(user(), rule, %{label: "Updated Label"})

      assert updated.label == "Updated Label"
    end

    test "returns error changeset with invalid attrs", %{source: source, destination: destination} do
      rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      assert {:error, changeset} =
               Transactions.update_transfer_rule(user(), rule, %{description_patterns: []})

      assert changeset.errors != []
    end
  end

  describe "delete_transfer_rule/1" do
    test "deletes a rule", %{source: source, destination: destination} do
      rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      assert {:ok, _} = Transactions.delete_transfer_rule(user(), rule)

      assert_raise Ecto.NoResultsError, fn ->
        Transactions.get_transfer_rule!(user(), rule.id)
      end
    end
  end

  describe "change_transfer_rule/2" do
    test "returns a changeset", %{source: source, destination: destination} do
      rule =
        transfer_rule_fixture(%{
          source_account_id: source.id,
          destination_account_id: destination.id
        })

      assert %Ecto.Changeset{} = Transactions.change_transfer_rule(rule)
    end
  end
end
