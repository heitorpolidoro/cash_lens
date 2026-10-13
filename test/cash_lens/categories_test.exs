defmodule CashLens.CategoriesTest do
  use CashLens.DataCase, async: false

  setup %{current_user_id: user_id} do
    {:ok, user: CashLens.Repo.get!(CashLens.Users.User, user_id)}
  end

  alias CashLens.Categories

  describe "categories" do
    alias CashLens.Categories.Category
    import CashLens.CategoriesFixtures

    test "list_categories/1 filters by name", %{user: user} do
      u = System.unique_integer([:positive])
      parent = category_fixture(name: "Moradia #{u}")
      _child = category_fixture(name: "Aluguel #{u}", parent_id: parent.id)

      results = Categories.list_categories(user, name: "Aluguel #{u}")
      assert Enum.map(results, & &1.name) == ["Aluguel #{u}"]
    end

    test "list_categories/0 links the parent struct for child categories", %{user: user} do
      u = System.unique_integer([:positive])
      parent = category_fixture(name: "Moradia #{u}")
      child = category_fixture(name: "Aluguel #{u}", parent_id: parent.id)

      linked_child = Enum.find(Categories.list_categories(user), &(&1.id == child.id))
      assert %Category{} = linked_child.parent
      assert linked_child.parent.id == parent.id
    end

    test "list_categories/0 returns all categories ordered by hierarchy and name", %{user: user} do
      # Use high unique base to avoid any clash
      u = System.unique_integer([:positive])
      p2_name = "B Parent #{u}"
      p1_name = "A Parent #{u}"

      _p2 = category_fixture(name: p2_name)
      p1 = category_fixture(name: p1_name)
      category_fixture(name: "Child 1", parent_id: p1.id)

      categories = Categories.list_categories(user)
      names = Enum.map(categories, & &1.name)

      assert p1_name in names
      assert p2_name in names

      assert Enum.all?(categories, fn c ->
               if c.parent_id, do: is_struct(c.parent, Category), else: is_nil(c.parent)
             end)
    end

    test "list_categories/0 sorts root categories first, then their children recursively", %{
      user: user
    } do
      saude = category_fixture(name: "Saude")
      _saude_consulta = category_fixture(name: "Consulta", parent_id: saude.id)

      casa = category_fixture(name: "Casa")
      casa_manutencao = category_fixture(name: "Manutencao", parent_id: casa.id)
      casa_manutencao_sofa = category_fixture(name: "Sofa", parent_id: casa_manutencao.id)

      _casa_manutencao_sofa_almofada =
        category_fixture(name: "Almofada", parent_id: casa_manutencao_sofa.id)

      # Add a root category that comes alphabetically between Casa and Manutencao
      _d = category_fixture(name: "D Root")

      categories = Categories.list_categories(user)
      names = Enum.map(categories, & &1.name)

      assert index_of(names, "Casa") < index_of(names, "Manutencao")
      assert index_of(names, "Manutencao") < index_of(names, "Sofa")
      assert index_of(names, "Saude") < index_of(names, "Consulta")

      # Root should come before children AND children should be grouped under parents.
      assert index_of(names, "Manutencao") + 1 == index_of(names, "Sofa")

      # Verify full hierarchy display for deep levels
      almofada = Enum.find(categories, &(&1.name == "Almofada"))
      assert Category.full_name(almofada) == "Casa > Manutencao > Sofa > Almofada"
    end

    defp index_of(list, element) do
      Enum.find_index(list, &(&1 == element))
    end

    test "get_category!/1 returns the category with given id", %{user: user} do
      category = category_fixture()
      fetched = Categories.get_category!(user, category.id)
      assert fetched.id == category.id
    end

    test "create_category/1 with valid data creates a category", %{user: user} do
      u = System.unique_integer([:positive])
      name = "variable category #{u}"
      valid_attrs = %{name: name, type: "variable"}

      assert {:ok, %Category{} = category} = Categories.create_category(user, valid_attrs)
      assert category.name == name
      assert category.type == "variable"
    end

    test "create_category/1 with parent_id creates a child category with hierarchical slug", %{
      user: user
    } do
      u = System.unique_integer([:positive])
      parent = category_fixture(name: "Finance #{u}")
      valid_attrs = %{name: "Banking", parent_id: parent.id}

      assert {:ok, %Category{} = child} = Categories.create_category(user, valid_attrs)
      assert child.parent_id == parent.id
      assert String.contains?(child.slug, "finance")
    end

    test "update_category/2 with invalid data returns error changeset", %{user: user} do
      category = category_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Categories.update_category(user, category, %{name: nil})

      assert fetched = Categories.get_category!(user, category.id)
      assert fetched.name == category.name
    end

    test "get_category_ids_with_children/1 returns IDs for the whole branch", %{user: user} do
      p = category_fixture(name: "Parent")
      c1 = category_fixture(name: "Child 1", parent_id: p.id)
      c2 = category_fixture(name: "Child 2", parent_id: p.id)
      gc1 = category_fixture(name: "Grandchild 1", parent_id: c1.id)

      ids = Categories.get_category_ids_with_children(user, p.id)
      assert length(ids) == 4
      assert p.id in ids
      assert c1.id in ids
      assert c2.id in ids
      assert gc1.id in ids

      assert Categories.get_category_ids_with_children(user, nil) == []
    end

    test "get_category_by_slug/1 returns the category with given slug", %{user: user} do
      category = category_fixture(name: "Unique Slug Test")
      assert fetched = Categories.get_category_by_slug(user, category.slug)
      assert fetched.id == category.id
    end

    test "change_category/1 returns a category changeset", %{user: user} do
      category = category_fixture()
      assert %Ecto.Changeset{} = Categories.change_category(category)
    end

    test "delete_category/1 deletes the category", %{user: user} do
      category = category_fixture()
      assert {:ok, %Category{}} = Categories.delete_category(user, category)
      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(user, category.id) end
    end

    test "delete_category/1 fails if category has children due to foreign key constraint", %{
      user: user
    } do
      parent = category_fixture()
      category_fixture(parent_id: parent.id)

      assert {:error, changeset} = Categories.delete_category(user, parent)
      assert changeset.errors[:children] != nil
    end

    test "create_category/1 fails when name is duplicated at the same level", %{user: user} do
      u = System.unique_integer([:positive])
      name = "Unique #{u}"
      category_fixture(name: name)
      assert {:error, changeset} = Categories.create_category(user, %{name: name})
      errors = errors_on(changeset)
      # Can fail on either name or slug constraint depending on DB execution
      assert "has already been taken" in (Map.get(errors, :name, []) ++ Map.get(errors, :slug, []))
    end

    test "Category.full_name/1 returns formatted name based on parent", %{user: user} do
      parent = %Category{name: "Fixed"}
      child = %Category{name: "Rent", parent: parent}
      standalone = %Category{name: "Food"}

      assert Category.full_name(child) == "Fixed > Rent"
      assert Category.full_name(standalone) == "Food"
      assert Category.full_name(%{not: "a category"}) == ""
    end
  end

  describe "slug generation" do
    alias CashLens.Categories.Category

    import CashLens.CategoriesFixtures

    test "does not generate a slug when the name is missing", %{user: user} do
      parent = category_fixture(%{name: "Slugless Parent"})

      changeset = Categories.change_category(%Category{}, %{"parent_id" => parent.id})

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      refute Ecto.Changeset.get_change(changeset, :slug)
    end
  end

  describe "group_by_parent/1" do
    import CashLens.CategoriesFixtures

    test "groups root categories with their children", %{user: user} do
      root = category_fixture(%{name: "Root A"})
      child_a = category_fixture(%{name: "Child A", parent_id: root.id})
      child_b = category_fixture(%{name: "Child B", parent_id: root.id})
      leaf = category_fixture(%{name: "Leaf"})

      tree = Categories.group_by_parent(Categories.list_categories(user))

      assert {found_root, children} = Enum.find(tree, fn {r, _} -> r.id == root.id end)
      assert found_root.id == root.id
      assert Enum.sort(Enum.map(children, & &1.id)) == Enum.sort([child_a.id, child_b.id])

      assert {_leaf, []} = Enum.find(tree, fn {r, _} -> r.id == leaf.id end)
    end

    test "nests a deeper descendant under its top-level ancestor", %{user: user} do
      root = category_fixture(%{name: "Root C"})
      child = category_fixture(%{name: "Child D", parent_id: root.id})
      grandchild = category_fixture(%{name: "Grandchild D", parent_id: child.id})

      tree = Categories.group_by_parent(Categories.list_categories(user))

      assert {_root, children} = Enum.find(tree, fn {r, _} -> r.id == root.id end)
      assert grandchild.id in Enum.map(children, & &1.id)
      refute Enum.any?(tree, fn {r, _} -> r.id in [child.id, grandchild.id] end)
    end

    test "returns an empty list for an empty category list", %{user: user} do
      assert Categories.group_by_parent([]) == []
    end

    test "ignores children whose parent is not in the list", %{user: user} do
      parent = category_fixture(%{name: "Root B"})
      child = category_fixture(%{name: "Child C", parent_id: parent.id})

      assert Categories.group_by_parent([child]) == []
    end
  end

  describe "cyclic parent_id data" do
    import CashLens.CategoriesFixtures
    import Ecto.Query
    alias CashLens.Categories.Category

    # No UI path can create a cycle, but nothing in the database prevents one,
    # and an unguarded ancestry walk does not fail on it — it never returns.
    # These run under a timeout so a regression reports a hang instead of
    # wedging the suite.
    defp within(timeout_ms, fun) do
      # The task is a new process: it acts for the same user as the test.
      user_id = CashLens.Repo.current_user_id()

      task =
        Task.async(fn ->
          CashLens.Repo.put_current_user_id(user_id)
          fun.()
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> flunk("hung for more than #{timeout_ms}ms instead of returning")
      end
    end

    defp make_cycle do
      a = category_fixture(%{name: "Cycle A"})
      b = category_fixture(%{name: "Cycle B", parent_id: a.id})

      {1, _} =
        CashLens.Repo.update_all(
          from(c in Category, where: c.id == ^a.id),
          set: [parent_id: b.id]
        )

      {a, b}
    end

    test "list_categories/1 terminates and truncates the ancestry at the cycle", %{user: user} do
      {a, b} = make_cycle()

      categories = within(5_000, fn -> Categories.list_categories(user) end)

      by_id = Map.new(categories, &{&1.id, &1})
      assert Map.has_key?(by_id, a.id)
      assert Map.has_key?(by_id, b.id)

      # The chain is cut where it would repeat, so the structure is finite and
      # every category is still returned rather than dropped.
      assert depth(by_id[a.id]) <= 3
      assert depth(by_id[b.id]) <= 3
    end

    test "full_name/1 terminates on a category loaded from cyclic data", %{user: user} do
      {a, _b} = make_cycle()

      categories = within(5_000, fn -> Categories.list_categories(user) end)
      cyclic = Enum.find(categories, &(&1.id == a.id))

      name = within(5_000, fn -> Category.full_name(cyclic) end)

      assert is_binary(name)
      assert name =~ "Cycle A"
    end

    test "group_by_parent/1 terminates on cyclic data", %{user: user} do
      make_cycle()

      categories = within(5_000, fn -> Categories.list_categories(user) end)
      tree = within(5_000, fn -> Categories.group_by_parent(categories) end)

      # Neither cyclic category has a top-level ancestor, so neither is a root
      # and neither is nested — but the call returns.
      assert is_list(tree)
    end

    defp depth(%Category{parent: %Category{} = parent}), do: 1 + depth(parent)
    defp depth(%Category{}), do: 1
  end

  describe "add_keyword/2" do
    import CashLens.CategoriesFixtures

    test "seeds the field on a category that has no keywords yet", %{user: user} do
      category = category_fixture(%{keywords: nil})

      assert {:ok, updated} = Categories.add_keyword(user, category, "COMGAS")
      assert updated.keywords == "COMGAS"
    end

    test "appends to an existing list in the format the field already holds", %{user: user} do
      category = category_fixture(%{keywords: "COMGAS"})

      assert {:ok, updated} = Categories.add_keyword(user, category, "SABESP")
      assert updated.keywords == "COMGAS, SABESP"
    end

    test "a keyword the category already carries changes nothing, whatever its case", %{
      user: user
    } do
      category = category_fixture(%{keywords: "COMGAS, SABESP"})

      assert {:ok, updated} = Categories.add_keyword(user, category, "comgas")
      assert updated.keywords == "COMGAS, SABESP"
    end

    test "surrounding and inner whitespace never makes a near-duplicate", %{user: user} do
      # The matcher collapses runs of whitespace before comparing, so a
      # description pasted with a double space is the same rule, not a new one.
      category = category_fixture(%{keywords: "PORTO SEGURO ADMINISTRADORA"})

      assert {:ok, updated} =
               Categories.add_keyword(user, category, "  PORTO  SEGURO ADMINISTRADORA ")

      assert updated.keywords == "PORTO SEGURO ADMINISTRADORA"
    end

    test "a blank keyword is a no-op rather than an error", %{user: user} do
      category = category_fixture(%{keywords: "COMGAS"})

      assert {:ok, updated} = Categories.add_keyword(user, category, "   ")
      assert updated.keywords == "COMGAS"
    end

    test "reads newline separators too, the way AutoCategorizer does", %{user: user} do
      # AutoCategorizer splits on commas AND newlines. A duplicate check that
      # only knew about commas would read "COMGAS\nSABESP" as one long keyword
      # and happily append a second SABESP.
      category = category_fixture(%{keywords: "COMGAS\nSABESP"})

      assert {:ok, updated} = Categories.add_keyword(user, category, "SABESP")
      assert updated.keywords == "COMGAS\nSABESP"
    end

    test "normalizes the stored keyword, so a pasted description lands clean", %{user: user} do
      category = category_fixture(%{keywords: nil})

      assert {:ok, updated} = Categories.add_keyword(user, category, "  PAG*Restaurante   Silva ")
      assert updated.keywords == "PAG*Restaurante Silva"
    end
  end

  describe "keyword_conflicts/1" do
    import CashLens.CategoriesFixtures

    test "a clean board reports nothing", %{user: user} do
      category_fixture(%{name: "Gás", keywords: "COMGAS"})
      category_fixture(%{name: "Água", keywords: "SABESP"})

      assert Categories.keyword_conflicts(Categories.list_categories(user)) == []
    end

    test "a keyword contained in another category's keyword is reported, shadowed side first", %{
      user: user
    } do
      # The real case: "PAG*ALEX HAIR STUDIO" matches both rules, and which one
      # wins is the physical row order, not a decision anyone made.
      pessoais = category_fixture(%{name: "Cuidados Pessoais", keywords: "HAIR, SEPHORA"})
      cabelo = category_fixture(%{name: "Cabeleireiro", keywords: "ALEX HAIR"})

      assert [conflict] = Categories.keyword_conflicts(Categories.list_categories(user))
      assert conflict.text == "HAIR"
      assert conflict.category.id == pessoais.id
      assert conflict.shadowed_by_text == "ALEX HAIR"
      assert conflict.shadowed_by.id == cabelo.id
    end

    test "two categories claiming the very same keyword are reported once, not twice", %{
      user: user
    } do
      category_fixture(%{name: "Mercado", keywords: "CARREFOUR"})
      category_fixture(%{name: "Combustível", keywords: "CARREFOUR"})

      assert [conflict] = Categories.keyword_conflicts(Categories.list_categories(user))
      assert conflict.text == "CARREFOUR"
      assert conflict.shadowed_by_text == "CARREFOUR"
      assert conflict.category.id != conflict.shadowed_by.id
    end

    test "case and spacing never hide a conflict", %{user: user} do
      category_fixture(%{name: "Mercado", keywords: "carrefour"})
      category_fixture(%{name: "Combustível", keywords: "  CARREFOUR  "})

      assert [_conflict] = Categories.keyword_conflicts(Categories.list_categories(user))
    end

    test "a category's own keywords never conflict with each other", %{user: user} do
      # Overlapping keywords inside one category are harmless: whichever
      # matches, the transaction lands in the same place.
      category_fixture(%{name: "Cuidados Pessoais", keywords: "HAIR, ALEX HAIR"})

      assert Categories.keyword_conflicts(Categories.list_categories(user)) == []
    end
  end

  describe "keyword_conflicts_for/2" do
    import CashLens.CategoriesFixtures

    test "warns about a keyword another category already claims", %{user: user} do
      mercado = category_fixture(%{name: "Mercado", keywords: "CARREFOUR"})
      combustivel = category_fixture(%{name: "Combustível", keywords: nil})

      assert [conflict] = Categories.keyword_conflicts_for(user, "CARREFOUR", combustivel.id)
      assert conflict.shadowed_by.id == mercado.id or conflict.category.id == mercado.id
    end

    test "warns when the new keyword would shadow another category's", %{user: user} do
      cabelo = category_fixture(%{name: "Cabeleireiro", keywords: "ALEX HAIR"})
      pessoais = category_fixture(%{name: "Cuidados Pessoais", keywords: nil})

      assert [conflict] = Categories.keyword_conflicts_for(user, "HAIR", pessoais.id)
      assert conflict.text == "HAIR"
      assert conflict.shadowed_by.id == cabelo.id
    end

    test "a keyword the category itself already has is not a conflict with itself", %{user: user} do
      pessoais = category_fixture(%{name: "Cuidados Pessoais", keywords: "HAIR"})

      assert Categories.keyword_conflicts_for(user, "ALEX HAIR", pessoais.id) == []
    end

    test "a blank keyword warns about nothing", %{user: user} do
      category_fixture(%{name: "Mercado", keywords: "CARREFOUR"})

      assert Categories.keyword_conflicts_for(user, "   ", Ecto.UUID.generate()) == []
    end

    test "an unrelated keyword warns about nothing", %{user: user} do
      category_fixture(%{name: "Mercado", keywords: "CARREFOUR"})
      outra = category_fixture(%{name: "Combustível", keywords: nil})

      assert Categories.keyword_conflicts_for(user, "IPIRANGA", outra.id) == []
    end
  end
end
