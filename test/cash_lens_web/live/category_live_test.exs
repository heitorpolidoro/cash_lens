defmodule CashLensWeb.CategoryLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.CategoriesFixtures

  @create_attrs %{name: "unique category name", type: "variable"}
  @update_attrs %{name: "some updated name", type: "fixed"}
  @invalid_attrs %{name: nil}
  defp create_category(_) do
    category = category_fixture()

    %{category: category}
  end

  describe "Index" do
    setup [:create_category]

    test "lists all categories", %{conn: conn, category: category} do
      {:ok, _index_live, html} = live(conn, ~p"/categories")

      assert html =~ "Categorias"
      assert html =~ category.name
    end

    test "saves new category", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "Nova Categoria")
               |> render_click()
               |> follow_redirect(conn, ~p"/categories/new")

      assert render(form_live) =~ "Nova Categoria"

      assert form_live
             |> form("#category-form", category: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      unique_name = "unique category #{System.unique_integer([:positive])}"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#category-form", category: %{@create_attrs | name: unique_name})
               |> render_submit()
               |> follow_redirect(conn, ~p"/categories")

      html = render(index_live)
      assert html =~ "Categoria criada com sucesso!"
      assert html =~ unique_name
    end

    test "updates category in listing", %{conn: conn, category: category} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#categories-#{category.id} a[href$='/edit']")
               |> render_click()
               |> follow_redirect(conn, ~p"/categories/#{category}/edit")

      assert render(form_live) =~ "Editar Categoria"

      assert form_live
             |> form("#category-form", category: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#category-form", category: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/categories")

      html = render(index_live)
      assert html =~ "Categoria atualizada!"
      assert html =~ "some updated name"
    end

    test "toggles category type between fixed and variable", %{conn: conn, category: category} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      # Initial state is variable based on category_fixture
      assert category.type == "variable"

      # Toggle to fixed
      index_live
      |> element("input[phx-click='toggle_fixed'][phx-value-id='#{category.id}']")
      |> render_click()

      assert CashLens.Categories.get_category!(category.id).type == "fixed"

      # Toggle back to variable
      index_live
      |> element("input[phx-click='toggle_fixed'][phx-value-id='#{category.id}']")
      |> render_click()

      assert CashLens.Categories.get_category!(category.id).type == "variable"
    end

    test "deletes category in listing", %{conn: conn, category: category} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      assert index_live
             |> element("#categories-#{category.id} button[phx-click='confirm_delete']")
             |> render_click()

      assert index_live |> element("button", "Sim, Excluir") |> render_click()
      refute has_element?(index_live, "#categories-#{category.id}")
    end

    test "cancels delete modal via close_modal", %{conn: conn, category: category} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      index_live
      |> element("#categories-#{category.id} button[phx-click='confirm_delete']")
      |> render_click()

      assert render(index_live) =~ "Excluir Categoria?"

      render_click(index_live, "close_modal", %{})
      refute render(index_live) =~ "Excluir Categoria?"
    end

    test "shows delete error when category has child dependencies", %{conn: conn} do
      parent = category_fixture(%{name: "Parent Cat"})
      _child = category_fixture(%{name: "Child Cat", parent_id: parent.id})

      {:ok, index_live, _html} = live(conn, ~p"/categories")

      index_live
      |> element("#categories-#{parent.id} button[phx-click='confirm_delete']")
      |> render_click()

      html = index_live |> element("button", "Sim, Excluir") |> render_click()
      assert html =~ "Não foi possível excluir a categoria"
    end

    test "renders reimbursable icon for default_reimbursable category", %{conn: conn} do
      category_fixture(%{name: "Reimbursable", default_reimbursable: true})
      {:ok, _live, html} = live(conn, ~p"/categories")
      assert html =~ "hero-banknotes"
    end
  end

  describe "Form error paths" do
    setup [:create_category]

    test "shows error when submitting invalid category on new", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/categories/new")

      html =
        form_live
        |> form("#category-form", category: %{name: nil})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "shows error when submitting invalid category on edit", %{
      conn: conn,
      category: category
    } do
      {:ok, form_live, _html} = live(conn, ~p"/categories/#{category}/edit")

      html =
        form_live
        |> form("#category-form", category: %{name: nil})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "Show" do
    setup [:create_category]

    test "displays category", %{conn: conn, category: category} do
      {:ok, _show_live, html} = live(conn, ~p"/categories/#{category}")

      assert html =~ "Category:"
      assert html =~ category.name
    end

    test "updates category and returns to index", %{conn: conn, category: category} do
      {:ok, show_live, _html} = live(conn, ~p"/categories/#{category}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Editar Categoria")
               |> render_click()
               |> follow_redirect(conn, ~p"/categories/#{category}/edit")

      assert render(form_live) =~ "Editar Categoria"

      assert form_live
             |> form("#category-form", category: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#category-form", category: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/categories")

      html = render(index_live)
      assert html =~ "Categoria atualizada!"
      assert html =~ "some updated name"
    end
  end
end
