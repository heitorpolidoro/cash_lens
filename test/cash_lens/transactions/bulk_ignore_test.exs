defmodule CashLens.Transactions.BulkIgnoreTest do
  use CashLens.DataCase, async: false
  alias CashLens.Transactions.BulkIgnorePattern

  describe "changeset/2" do
    test "validates required pattern" do
      changeset = BulkIgnorePattern.changeset(%BulkIgnorePattern{}, %{})
      assert %{pattern: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates regex pattern" do
      # Valid regex
      changeset = BulkIgnorePattern.changeset(%BulkIgnorePattern{}, %{pattern: "COMPRA.*"})
      assert changeset.valid?

      # Invalid regex
      changeset = BulkIgnorePattern.changeset(%BulkIgnorePattern{}, %{pattern: "[UNCLOSED"})
      assert %{pattern: ["Regex inválida"]} = errors_on(changeset)
    end

    test "unique constraint on pattern" do
      {:ok, _} =
        Repo.insert(BulkIgnorePattern.changeset(%BulkIgnorePattern{}, %{pattern: "DUPLICATE"}))

      changeset = BulkIgnorePattern.changeset(%BulkIgnorePattern{}, %{pattern: "DUPLICATE"})
      assert {:error, changeset} = Repo.insert(changeset)
      assert %{pattern: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
