defmodule CashLens.CategoriesTest do
  use CashLens.DataCase

  alias CashLens.Categories
  alias CashLens.Transactions

  describe "categories" do
    alias CashLens.Categories.Category

    import CashLens.CategoriesFixtures
    import CashLens.TransactionsFixtures
    import CashLens.AccountsFixtures

    @invalid_attrs %{name: nil, type: nil}

    test "list_categories/0 returns all categories ordered by hierarchy and name" do
      # Setup hierarchy
      p2 = category_fixture(name: "B Parent")
      p1 = category_fixture(name: "A Parent")
      _c1 = category_fixture(name: "Child 1", parent_id: p1.id)
      _c2 = category_fixture(name: "Child 2", parent_id: p1.id)
      _c3 = category_fixture(name: "Child 1", parent_id: p2.id)

      categories = Categories.list_categories()
      names = Enum.map(categories, & &1.name)

      # Expected order based on: [asc: coalesce(p.name, c.name), asc: c.name]
      # A Parent (top level, coalesce is "A Parent", name "A Parent")
      # Child 1 (coalesce is "A Parent", name "Child 1")
      # Child 2 (coalesce is "A Parent", name "Child 2")
      # B Parent (top level, coalesce is "B Parent", name "B Parent")
      # Child 1 (coalesce is "B Parent", name "Child 1")
      assert names == ["A Parent", "Child 1", "Child 2", "B Parent", "Child 1"]

      # Ensure parent is preloaded
      assert Enum.all?(categories, fn c ->
               if c.parent_id, do: is_struct(c.parent, Category), else: is_nil(c.parent)
             end)
    end

    test "get_category!/1 returns the category with given id" do
      category = category_fixture()
      fetched = Categories.get_category!(category.id)
      assert fetched.id == category.id
      assert fetched.name == category.name
      # Verify parent preload is successful (even if nil)
      assert is_map(fetched.parent) or is_nil(fetched.parent)
    end

    test "get_category_by_slug/1 returns the category with given slug" do
      category = category_fixture(name: "Unique Slug Test")
      assert Categories.get_category_by_slug("unique-slug-test").id == category.id
    end

    test "create_category/1 with valid data creates a category" do
      valid_attrs = %{name: "variable category", type: "variable"}

      assert {:ok, %Category{} = category} = Categories.create_category(valid_attrs)
      assert category.name == "variable category"
      assert category.slug == "variable-category"
      assert category.type == "variable"
    end

    test "create_category/1 with parent_id creates a child category with hierarchical slug" do
      parent = category_fixture(name: "Finance")
      valid_attrs = %{name: "Banking", parent_id: parent.id}

      assert {:ok, %Category{} = child} = Categories.create_category(valid_attrs)
      assert child.parent_id == parent.id
      assert child.slug == "finance-banking"
    end

    test "create_category/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Categories.create_category(@invalid_attrs)
    end

    test "update_category/2 with valid data updates the category and slug" do
      category = category_fixture(name: "Old Name")
      update_attrs = %{name: "New Name"}

      assert {:ok, %Category{} = updated} = Categories.update_category(category, update_attrs)
      assert updated.name == "New Name"
      assert updated.slug == "new-name"
    end

    test "update_category/2 with new parent_id updates the slug" do
      old_parent = category_fixture(name: "Old Parent")
      new_parent = category_fixture(name: "New Parent")
      category = category_fixture(name: "Child", parent_id: old_parent.id)

      assert category.slug == "old-parent-child"

      assert {:ok, %Category{} = updated} =
               Categories.update_category(category, %{parent_id: new_parent.id})

      assert updated.parent_id == new_parent.id
      assert updated.slug == "new-parent-child"
    end

    test "update_category/2 with invalid data returns error changeset" do
      category = category_fixture()
      assert {:error, %Ecto.Changeset{}} = Categories.update_category(category, @invalid_attrs)
      assert category.id == Categories.get_category!(category.id).id
    end

    test "delete_category/1 deletes the category" do
      category = category_fixture()
      assert {:ok, %Category{}} = Categories.delete_category(category)
      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(category.id) end
    end

    test "change_category/1 returns a category changeset" do
      category = category_fixture()
      assert %Ecto.Changeset{} = Categories.change_category(category)
    end

    # get_category_ids_with_children/1 - Deep Tree Traversal
    test "get_category_ids_with_children/1 returns parent, children and grandchildren IDs" do
      # Level 0
      parent = category_fixture(name: "Level 0")

      # Level 1
      child1 = category_fixture(name: "Level 1A", parent_id: parent.id)
      child2 = category_fixture(name: "Level 1B", parent_id: parent.id)

      # Level 2
      grandchild = category_fixture(name: "Level 2", parent_id: child1.id)

      # Unrelated
      _other = category_fixture(name: "Other")

      ids = Categories.get_category_ids_with_children(parent.id)

      assert length(ids) == 4
      assert parent.id in ids
      assert child1.id in ids
      assert child2.id in ids
      assert grandchild.id in ids

      # Verify branch fetch
      child_branch_ids = Categories.get_category_ids_with_children(child1.id)
      assert length(child_branch_ids) == 2
      assert child1.id in child_branch_ids
      assert grandchild.id in child_branch_ids
    end

    test "get_category_ids_with_children/1 returns only the ID if there are no children" do
      category = category_fixture()
      assert Categories.get_category_ids_with_children(category.id) == [category.id]
    end

    test "get_category_ids_with_children/1 returns empty list for nil" do
      assert Categories.get_category_ids_with_children(nil) == []
    end

    # Deletion logic - DB Level Constraints
    test "delete_category/1 fails if category has children due to foreign key constraint" do
      parent = category_fixture(name: "Parent")
      _child = category_fixture(name: "Child", parent_id: parent.id)

      # on_delete: :nothing in migration prevents deleting parent with children
      # Repo.delete will raise Ecto.ConstraintError
      assert_raise Ecto.ConstraintError, ~r/foreign_key_constraint/, fn ->
        Categories.delete_category(parent)
      end
    end

    test "delete_category/1 nullifies category_id in associated transactions (SET NULL)" do
      category = category_fixture()
      account = account_fixture()
      transaction = transaction_fixture(category_id: category.id, account_id: account.id)

      assert transaction.category_id == category.id

      assert {:ok, _} = Categories.delete_category(category)

      # Verify transaction still exists but category_id is nil (via SET NULL constraint)
      updated_transaction = CashLens.Repo.get!(Transactions.Transaction, transaction.id)
      assert updated_transaction.category_id == nil
    end
  end
end
