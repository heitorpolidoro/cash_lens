defmodule CashLensWeb.CategoryLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.CategoriesFixtures

  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLens.Repo

  @fixo_hint "Fixo (Contas Essenciais): entra na previsão de caixa em /forecast como compromisso recorrente."

  defp create_category(_) do
    category = category_fixture()

    %{category: category}
  end

  defp create_tree(_) do
    root = category_fixture(%{name: "Moradia", type: "fixed"})

    child =
      category_fixture(%{
        name: "Energia Elétrica",
        parent_id: root.id,
        type: "fixed",
        keywords: "enel, comgas"
      })

    %{root: root, child: child}
  end

  # Strips every tag so only the visible text of the fragment is left, which is
  # how the assertions about "no visible label" tell text apart from `title` and
  # `aria-label` attributes.
  defp visible_text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The `value` of every option the parent select offers, excluding the empty
  # "no parent" prompt.
  defp offered_parent_ids(html) do
    case Regex.run(~r/<select[^>]*name="category\[parent_id\]".*?<\/select>/s, html) do
      nil -> []
      [select] -> Regex.scan(~r/<option value="([^"]+)"/, select) |> Enum.map(&Enum.at(&1, 1))
    end
  end

  describe "Index tree" do
    setup [:create_tree]

    test "renders roots with nested subcategories", %{conn: conn, root: root, child: child} do
      {:ok, live, html} = live(conn, ~p"/categories")

      assert html =~ "Árvore de Categorias"
      assert html =~ root.name
      assert html =~ child.name

      assert has_element?(live, "#category-#{root.id}")
      assert has_element?(live, "#group-#{root.id} #category-#{child.id}")
    end

    test "renders the keyword chips of a subcategory", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      text = visible_text(live, "#category-#{child.id}")
      assert text =~ "enel"
      assert text =~ "comgas"
    end

    test "collapses and expands a single group", %{conn: conn, root: root, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      assert has_element?(live, "#category-#{child.id}")

      live |> element("#toggle-group-#{root.id}") |> render_click()
      refute has_element?(live, "#category-#{child.id}")

      live |> element("#toggle-group-#{root.id}") |> render_click()
      assert has_element?(live, "#category-#{child.id}")
    end

    test "collapses and expands every group at once", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#collapse-all") |> render_click()
      refute has_element?(live, "#category-#{child.id}")

      live |> element("#expand-all") |> render_click()
      assert has_element?(live, "#category-#{child.id}")
    end

    test "keeps the collapsed state across a search", %{conn: conn, root: root, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#collapse-all") |> render_click()

      live
      |> form("#category-search-form", %{"search" => "Moradia"})
      |> render_change()

      assert has_element?(live, "#category-#{root.id}")
      refute has_element?(live, "#category-#{child.id}")
    end

    test "shows no summary or metric counter cards", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      refute has_element?(live, ".stats")
      refute has_element?(live, ".stat")
      refute has_element?(live, ".stat-value")
    end
  end

  describe "Index filters" do
    setup [:create_tree]

    test "type tab labels carry no counts", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      for {id, label} <- [
            {"tab-all", "Todas"},
            {"tab-fixed", "Custos Fixos"},
            {"tab-variable", "Variáveis"},
            {"tab-reimbursable", "Reembolsáveis"}
          ] do
        text = visible_text(live, "##{id}")
        assert text == label
        refute text =~ ~r/\d/
      end
    end

    test "filters by fixed, variable and reimbursable", %{conn: conn, root: root} do
      variable = category_fixture(%{name: "Lazer", type: "variable"})
      reimbursable = category_fixture(%{name: "Saúde", default_reimbursable: true})

      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#tab-fixed") |> render_click()
      assert has_element?(live, "#category-#{root.id}")
      refute has_element?(live, "#category-#{variable.id}")

      live |> element("#tab-variable") |> render_click()
      assert has_element?(live, "#category-#{variable.id}")
      refute has_element?(live, "#category-#{root.id}")

      live |> element("#tab-reimbursable") |> render_click()
      assert has_element?(live, "#category-#{reimbursable.id}")
      refute has_element?(live, "#category-#{root.id}")

      live |> element("#tab-all") |> render_click()
      assert has_element?(live, "#category-#{root.id}")
      assert has_element?(live, "#category-#{variable.id}")
    end

    test "a type tab never lists subcategories of the other type", %{conn: conn, root: root} do
      variable_child =
        category_fixture(%{name: "Decoração", parent_id: root.id, type: "variable"})

      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#tab-fixed") |> render_click()

      assert has_element?(live, "#category-#{root.id}")
      refute has_element?(live, "#category-#{variable_child.id}")

      live |> element("#tab-all") |> render_click()
      assert has_element?(live, "#category-#{variable_child.id}")
    end

    test "searches by category name", %{conn: conn, root: root} do
      other = category_fixture(%{name: "Transporte"})

      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> form("#category-search-form", %{"search" => "morad"}) |> render_change()

      assert has_element?(live, "#category-#{root.id}")
      refute has_element?(live, "#category-#{other.id}")
    end

    test "searches by keyword and keeps the matching subcategory visible", %{
      conn: conn,
      root: root,
      child: child
    } do
      other = category_fixture(%{name: "Transporte", keywords: "uber"})

      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> form("#category-search-form", %{"search" => "enel"}) |> render_change()

      assert has_element?(live, "#category-#{root.id}")
      assert has_element?(live, "#category-#{child.id}")
      refute has_element?(live, "#category-#{other.id}")
    end
  end

  describe "Index actions" do
    setup [:create_tree]

    test "edit and delete are icon-only with accessible names", %{
      conn: conn,
      root: root,
      child: child
    } do
      {:ok, live, html} = live(conn, ~p"/categories")

      tree_text = visible_text(live, "#category-tree")
      refute tree_text =~ "Editar"
      refute tree_text =~ "Excluir"

      assert html =~ ~s(aria-label="Editar categoria")
      assert html =~ ~s(aria-label="Excluir categoria")
      assert html =~ ~s(aria-label="Editar subcategoria")
      assert html =~ ~s(aria-label="Excluir subcategoria")

      for {selector, name, icon, other_icon} <- [
            {"#edit-category-#{root.id}", "Editar categoria", "hero-pencil", "hero-trash"},
            {"#delete-category-#{root.id}", "Excluir categoria", "hero-trash", "hero-pencil"},
            {"#edit-category-#{child.id}", "Editar subcategoria", "hero-pencil", "hero-trash"},
            {"#delete-category-#{child.id}", "Excluir subcategoria", "hero-trash", "hero-pencil"}
          ] do
        markup = live |> element(selector) |> render()
        assert markup =~ ~s(title="#{name}")
        assert markup =~ ~s(aria-label="#{name}")
        assert markup =~ icon
        refute markup =~ other_icon
      end
    end

    test "the delete icon opens the confirm modal", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      html = live |> element("#delete-category-#{child.id}") |> render_click()

      assert html =~ "Excluir Categoria?"
    end

    test "the index renders the Fixo hint", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/categories")

      assert html =~ @fixo_hint
    end

    test "quick toggle switches a subcategory between fixed and variable", %{
      conn: conn,
      child: child
    } do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live
      |> element("input[phx-click='toggle_fixed'][phx-value-id='#{child.id}']")
      |> render_click()

      assert Categories.get_category!(child.id).type == "variable"

      live
      |> element("input[phx-click='toggle_fixed'][phx-value-id='#{child.id}']")
      |> render_click()

      assert Categories.get_category!(child.id).type == "fixed"
    end

    test "quick toggle on the root card switches the type", %{conn: conn, root: root} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      markup = live |> element("#toggle-type-#{root.id}") |> render()
      assert markup =~ "Fixo (Contas Essenciais)"

      live |> element("#toggle-type-#{root.id}") |> render_click()
      assert Categories.get_category!(root.id).type == "variable"
    end

    test "renders the reimbursable badges", %{conn: conn, root: root} do
      reimbursable_root = category_fixture(%{name: "Saúde", default_reimbursable: true})

      category_fixture(%{
        name: "Consultas",
        parent_id: root.id,
        default_reimbursable: true
      })

      {:ok, live, _html} = live(conn, ~p"/categories")

      assert visible_text(live, "#category-#{reimbursable_root.id}") =~ "Reembolsável por Padrão"
      assert render(live) =~ "Marca Reembolso"
    end
  end

  describe "Index delete" do
    setup [:create_tree]

    test "confirming deletes a leaf category", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      html = live |> element("#delete-category-#{child.id}") |> render_click()

      assert html =~
               "Esta ação não pode ser desfeita. Excluir &quot;#{child.name}&quot; permanentemente?"

      refute live |> element("#confirm-delete-button") |> render() =~ "disabled"

      live |> element("#confirm-delete-button") |> render_click()

      refute has_element?(live, "#category-#{child.id}")
      refute Repo.get(Category, child.id)
    end

    test "a root with children shows the warning and a disabled confirm button", %{
      conn: conn,
      root: root
    } do
      {:ok, live, _html} = live(conn, ~p"/categories")

      html = live |> element("#delete-category-#{root.id}") |> render_click()

      assert html =~
               "A categoria &quot;#{root.name}&quot; possui subcategorias. Reatribua ou exclua as subcategorias antes de excluir esta categoria."

      assert live |> element("#confirm-delete-button") |> render() =~ "disabled"

      assert Repo.get(Category, root.id)
      assert has_element?(live, "#category-#{root.id}")
    end

    test "the database constraint still blocks a delete that bypasses the pre-check", %{
      conn: conn,
      root: root
    } do
      {:ok, live, _html} = live(conn, ~p"/categories")

      html = render_click(live, "delete", %{"id" => root.id})

      assert html =~ "Não foi possível excluir a categoria"
      assert Repo.get(Category, root.id)
    end

    test "cancelling closes the confirm modal", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#delete-category-#{child.id}") |> render_click()
      assert render(live) =~ "Excluir Categoria?"

      render_click(live, "close_modal", %{})
      refute render(live) =~ "Excluir Categoria?"
    end
  end

  describe "Index form modal" do
    setup [:create_tree]

    test "opens the new category modal from the header", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      html = live |> element("#new-category-button") |> render_click()

      assert_patch(live, ~p"/categories/new")
      assert html =~ "Nova Categoria"
      assert has_element?(live, "#category-form")
    end

    test "the modal renders the Fixo hint and a single reimbursable label", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      html = render(live)
      assert html =~ @fixo_hint
      assert html =~ "Reembolsável por Padrão?"
      refute html =~ "Transações nesta categoria serão criadas com status de reembolso"
    end

    test "creates a root category", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      assert live
             |> form("#category-form", category: %{name: ""})
             |> render_change() =~ "can&#39;t be blank"

      live
      |> form("#category-form",
        category: %{name: "Educação", type: "variable", keywords: "escola, curso"}
      )
      |> render_submit()

      assert_patch(live, ~p"/categories")
      html = render(live)
      assert html =~ "Categoria criada com sucesso!"
      assert html =~ "Educação"
    end

    test "creates a subcategory with the parent pre-selected from the root card", %{
      conn: conn,
      root: root
    } do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#add-subcategory-#{root.id}") |> render_click()
      assert_patch(live, ~p"/categories/new?parent_id=#{root.id}")

      assert live
             |> element("#category-form select[name='category[parent_id]'] option[selected]")
             |> render() =~ root.name

      live
      |> form("#category-form", category: %{name: "Água", type: "fixed"})
      |> render_submit()

      assert_patch(live, ~p"/categories")

      created = Categories.list_categories() |> Enum.find(&(&1.name == "Água"))
      assert created.parent_id == root.id
      assert has_element?(live, "#group-#{root.id} #category-#{created.id}")
    end

    test "edits a category through the modal", %{conn: conn, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories")

      live |> element("#edit-category-#{child.id}") |> render_click()
      assert_patch(live, ~p"/categories/#{child.id}/edit")

      assert live
             |> form("#category-form", category: %{name: ""})
             |> render_change() =~ "can&#39;t be blank"

      live
      |> form("#category-form", category: %{name: "Energia e Gás", type: "fixed"})
      |> render_submit()

      assert_patch(live, ~p"/categories")
      html = render(live)
      assert html =~ "Categoria atualizada!"
      assert html =~ "Energia e Gás"
    end

    test "closes the modal without saving", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      live |> element("#category-form-modal-close") |> render_click()
      assert_patch(live, ~p"/categories")

      refute has_element?(live, "#category-form")
    end

    test "keeps the modal open when submitting a blank name", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      html =
        live
        |> form("#category-form", category: %{name: "", type: "variable"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(live, "#category-form")
    end

    test "keeps the modal open when creating a duplicate name", %{conn: conn, root: root} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      html =
        live
        |> form("#category-form", category: %{name: root.name, type: "variable"})
        |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(live, "#category-form")
    end

    test "keeps the modal open when an edit collides with a sibling", %{
      conn: conn,
      root: root,
      child: child
    } do
      sibling = category_fixture(%{name: "Água", parent_id: root.id})

      {:ok, live, _html} = live(conn, ~p"/categories/#{child.id}/edit")

      html =
        live
        |> form("#category-form", category: %{name: sibling.name, type: "fixed"})
        |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(live, "#category-form")
    end

    test "only root categories are offered as parent, so nothing created here can be unreachable",
         %{conn: conn, root: root, child: child} do
      {:ok, live, _html} = live(conn, ~p"/categories/new")

      assert has_element?(
               live,
               "#category-form select[name='category[parent_id]'] option[value='#{root.id}']"
             )

      refute has_element?(
               live,
               "#category-form select[name='category[parent_id]'] option[value='#{child.id}']"
             )
    end

    test "a category created under every offered parent is rendered on the tree", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/categories/new")

      parent_ids = offered_parent_ids(html)
      assert parent_ids != []

      for {parent_id, index} <- Enum.with_index(parent_ids) do
        {:ok, form_live, _html} = live(conn, ~p"/categories/new?parent_id=#{parent_id}")

        form_live
        |> form("#category-form", category: %{name: "Invariante #{index}", type: "variable"})
        |> render_submit()

        created = Enum.find(Categories.list_categories(), &(&1.name == "Invariante #{index}"))
        assert created.parent_id == parent_id

        {:ok, index_live, _html} = live(conn, ~p"/categories")
        assert has_element?(index_live, "#category-#{created.id}")
      end
    end

    test "an existing deeper category is still rendered and editable", %{
      conn: conn,
      root: root,
      child: child
    } do
      # Pre-existing data: three levels deep, which the form no longer allows
      # to be created but which must not become unreachable.
      grandchild = category_fixture(%{name: "Bandeira Vermelha", parent_id: child.id})

      {:ok, live, _html} = live(conn, ~p"/categories")

      assert has_element?(live, "#group-#{root.id} #category-#{grandchild.id}")

      live |> element("#delete-category-#{grandchild.id}") |> render_click()
      live |> element("#confirm-delete-button") |> render_click()

      refute Repo.get(Category, grandchild.id)
    end

    test "editing a deeper category keeps its current parent selectable", %{
      conn: conn,
      child: child
    } do
      grandchild = category_fixture(%{name: "Bandeira Verde", parent_id: child.id})

      {:ok, live, _html} = live(conn, ~p"/categories/#{grandchild.id}/edit")

      assert live
             |> element("#category-form select[name='category[parent_id]'] option[selected]")
             |> render() =~ child.name

      live
      |> form("#category-form", category: %{name: "Bandeira Amarela"})
      |> render_submit()

      assert Repo.get(Category, grandchild.id).parent_id == child.id
    end

    test "does not offer a category as its own parent", %{conn: conn, root: root} do
      {:ok, live, _html} = live(conn, ~p"/categories/#{root.id}/edit")

      refute has_element?(
               live,
               "#category-form select[name='category[parent_id]'] option[value='#{root.id}']"
             )
    end
  end

  describe "Show" do
    setup [:create_category]

    test "displays category", %{conn: conn, category: category} do
      {:ok, _show_live, html} = live(conn, ~p"/categories/#{category}")

      assert html =~ "Category:"
      assert html =~ category.name
    end

    test "edit link opens the index modal", %{conn: conn, category: category} do
      {:ok, show_live, _html} = live(conn, ~p"/categories/#{category}")

      assert {:ok, index_live, _html} =
               show_live
               |> element("a", "Editar Categoria")
               |> render_click()
               |> follow_redirect(conn, ~p"/categories/#{category}/edit")

      assert has_element?(index_live, "#category-form")
    end
  end
end
