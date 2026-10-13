defmodule CashLens.CategoriesTenancyTest do
  use CashLens.DataCase, async: false

  import CashLens.CategoriesFixtures

  alias CashLens.Categories
  alias CashLens.Tenancy

  setup do
    %{a: a, b: b} = cross_tenant()
    root = category_fixture(%{user: a, name: "A root", keywords: "ALPHA"})
    child = category_fixture(%{user: a, name: "A child", parent_id: root.id})
    {:ok, a: a, b: b, root: root, child: child}
  end

  defp as(user, fun), do: Tenancy.acting_as(user, fun)

  describe "user B cannot see user A's categories" do
    test "lists and lookups", %{b: b, root: root} do
      as(b, fn ->
        assert Categories.list_categories(b) == []
        assert Categories.list_categories(b, name: "A root") == []
        assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(b, root.id) end
        assert Categories.get_category_by_slug(b, root.slug) == nil
        assert Categories.get_category_ids_with_children(b, root.id) == []
        assert Categories.keyword_conflicts_for(b, "ALPHA", Ecto.UUID.generate()) == []
      end)
    end

    test "user A sees the whole tree", %{a: a, root: root, child: child} do
      as(a, fn ->
        assert Enum.sort(Categories.get_category_ids_with_children(a, root.id)) ==
                 Enum.sort([root.id, child.id])

        assert length(Categories.list_categories(a)) == 2
      end)
    end

    test "the descendant walk never enters another user's categories", %{b: b, root: root} do
      # A child of B pointing at A's root cannot be created through the context,
      # so plant it directly to prove the recursive step is scoped too.
      as(b, fn ->
        {:ok, own} = Categories.create_category(b, %{name: "B own"})
        planted = own |> Ecto.Changeset.change(parent_id: root.id) |> Repo.update!()
        assert planted.parent_id == root.id
        assert Categories.get_category_ids_with_children(b, root.id) == []
        assert Categories.get_category_ids_with_children(b, own.id) == [own.id]
      end)
    end
  end

  describe "user B cannot change user A's categories" do
    test "update, delete and add_keyword answer :not_found", %{a: a, b: b, root: root} do
      as(b, fn ->
        assert {:error, :not_found} = Categories.update_category(b, root, %{name: "hijacked"})
        assert {:error, :not_found} = Categories.delete_category(b, root)
        assert {:error, :not_found} = Categories.add_keyword(b, root, "BETA")
      end)

      as(a, fn ->
        unchanged = Categories.get_category!(a, root.id)
        assert unchanged.name == "A root"
        assert unchanged.keywords == "ALPHA"
      end)
    end
  end

  describe "create_category/2" do
    test "sets the owner and ignores a user_id in attrs", %{a: a, b: b} do
      as(b, fn ->
        assert {:ok, created} =
                 Categories.create_category(b, %{"name" => "Mine", "user_id" => a.id})

        assert created.user_id == b.id
      end)
    end

    test "rejects a parent_id owned by another user", %{b: b, root: root} do
      as(b, fn ->
        assert {:error, changeset} =
                 Categories.create_category(b, %{name: "Orphan", parent_id: root.id})

        assert %{parent_id: ["does not exist"]} = errors_on(changeset)
      end)
    end

    test "accepts a parent_id owned by the same user", %{a: a, root: root} do
      as(a, fn ->
        assert {:ok, created} =
                 Categories.create_category(a, %{name: "Sibling", parent_id: root.id})

        assert created.parent_id == root.id
      end)
    end
  end

  describe "update_category/3" do
    test "rejects moving a category under another user's parent", %{b: b, root: root} do
      as(b, fn ->
        {:ok, own} = Categories.create_category(b, %{name: "B own"})

        assert {:error, changeset} = Categories.update_category(b, own, %{parent_id: root.id})
        assert %{parent_id: ["does not exist"]} = errors_on(changeset)
      end)
    end
  end

  describe "category events" do
    test "are broadcast on the owner's topic only", %{a: a, b: b} do
      Categories.subscribe(b)
      as(a, fn -> {:ok, _} = Categories.create_category(a, %{name: "Private"}) end)
      refute_receive {:category_created, _}, 100

      Categories.subscribe(a)
      as(a, fn -> {:ok, _} = Categories.create_category(a, %{name: "Visible"}) end)
      assert_receive {:category_created, %{name: "Visible"}}
    end
  end
end
