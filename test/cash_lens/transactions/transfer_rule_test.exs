defmodule CashLens.Transactions.TransferRuleTest do
  use CashLens.DataCase, async: false

  alias CashLens.Transactions.TransferRule
  import CashLens.AccountsFixtures

  describe "changeset/2" do
    setup do
      source = account_fixture()
      destination = account_fixture()
      %{source: source, destination: destination}
    end

    test "valid changeset with required fields", %{source: source, destination: destination} do
      attrs = %{
        description_patterns: ["PAY BILL"],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with optional label", %{source: source, destination: destination} do
      attrs = %{
        label: "My Rule",
        description_patterns: ["PAY BILL"],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :label) == "My Rule"
    end

    test "valid changeset with multiple patterns", %{source: source, destination: destination} do
      attrs = %{
        description_patterns: ["PATTERN ONE", "PATTERN TWO"],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert changeset.valid?
    end

    test "invalid when description_patterns is missing", %{
      source: source,
      destination: destination
    } do
      attrs = %{
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert %{description_patterns: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when description_patterns is empty list", %{
      source: source,
      destination: destination
    } do
      attrs = %{
        description_patterns: [],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      refute changeset.valid?
    end

    test "invalid when source_account_id is missing", %{destination: destination} do
      attrs = %{
        description_patterns: ["PAY BILL"],
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert %{source_account_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when destination_account_id is missing", %{source: source} do
      attrs = %{
        description_patterns: ["PAY BILL"],
        source_account_id: source.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert %{destination_account_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid when source and destination are the same account", %{source: source} do
      attrs = %{
        description_patterns: ["PAY BILL"],
        source_account_id: source.id,
        destination_account_id: source.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert %{destination_account_id: [_]} = errors_on(changeset)
    end

    test "invalid when all patterns are blank (Ecto filters empty strings, leaving empty list)",
         %{
           source: source,
           destination: destination
         } do
      # Ecto's {:array, :string} cast removes empty strings, so passing only blanks
      # results in an empty list which triggers the "can't be blank" validation.
      attrs = %{
        description_patterns: ["", ""],
        source_account_id: source.id,
        destination_account_id: destination.id
      }

      changeset = TransferRule.changeset(%TransferRule{}, attrs)
      assert %{description_patterns: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
