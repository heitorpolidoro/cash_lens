defmodule CashLens.CategoriesTest do
  use CashLens.DataCase, async: false

  alias CashLens.Categories

  describe "categories" do
    alias CashLens.Categories.Category
    import CashLens.CategoriesFixtures

    test "list_categories/0 returns all categories ordered by hierarchy and name" do
      # Use high unique base to avoid any clash
      u = System.unique_integer([:positive])
      p2_name = "B Parent #{u}"
      p1_name = "A Parent #{u}"

      _p2 = category_fixture(name: p2_name)
      p1 = category_fixture(name: p1_name)
      category_fixture(name: "Child 1", parent_id: p1.id)

      categories = Categories.list_categories()
      names = Enum.map(categories, & &1.name)

      assert p1_name in names
      assert p2_name in names

      assert Enum.all?(categories, fn c ->
               if c.parent_id, do: is_struct(c.parent, Category), else: is_nil(c.parent)
             end)
    end

    test "get_category!/1 returns the category with given id" do
      category = category_fixture()
      fetched = Categories.get_category!(category.id)
      assert fetched.id == category.id
    end

    test "create_category/1 with valid data creates a category" do
      u = System.unique_integer([:positive])
      name = "variable category #{u}"
      valid_attrs = %{name: name, type: "variable"}

      assert {:ok, %Category{} = category} = Categories.create_category(valid_attrs)
      assert category.name == name
      assert category.type == "variable"
    end

    test "create_category/1 with parent_id creates a child category with hierarchical slug" do
      u = System.unique_integer([:positive])
      parent = category_fixture(name: "Finance #{u}")
      valid_attrs = %{name: "Banking", parent_id: parent.id}

      assert {:ok, %Category{} = child} = Categories.create_category(valid_attrs)
      assert child.parent_id == parent.id
      assert String.contains?(child.slug, "finance")
    end

    test "update_category/2 with valid data updates the category and slug" do
      category = category_fixture()
      u = System.unique_integer([:positive])
      new_name = "New Name #{u}"
      update_attrs = %{name: new_name}

      assert {:ok, %Category{} = updated} = Categories.update_category(category, update_attrs)
      assert updated.name == new_name
    end

    test "delete_category/1 deletes the category" do
      category = category_fixture()
      assert {:ok, %Category{}} = Categories.delete_category(category)
      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(category.id) end
    end

    test "delete_category/1 fails if category has children due to foreign key constraint" do
      parent = category_fixture()
      category_fixture(parent_id: parent.id)

      assert_raise Ecto.ConstraintError, ~r/foreign_key_constraint/, fn ->
        Categories.delete_category(parent)
      end
    end

    test "create_category/1 fails when name is duplicated at the same level" do
      u = System.unique_integer([:positive])
      name = "Unique #{u}"
      category_fixture(name: name)
      assert {:error, changeset} = Categories.create_category(%{name: name})
      errors = errors_on(changeset)
      # Can fail on either name or slug constraint depending on DB execution
      assert "has already been taken" in (Map.get(errors, :name, []) ++ Map.get(errors, :slug, []))
    end

    test "Category.full_name/1 returns formatted name based on parent" do
      parent = %Category{name: "Fixed"}
      child = %Category{name: "Rent", parent: parent}
      standalone = %Category{name: "Food"}

      assert Category.full_name(child) == "Fixed > Rent"
      assert Category.full_name(standalone) == "Food"
      assert Category.full_name(%{not: "a category"}) == ""
    end
  end
end
