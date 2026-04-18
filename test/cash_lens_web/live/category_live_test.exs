defmodule CashLensWeb.CategoryLiveTest do
  use CashLensWeb.ConnCase

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

      assert html =~ "Listando Categorias"
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

      assert {:ok, index_live, _html} =
               form_live
               |> form("#category-form", category: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/categories")

      html = render(index_live)
      assert html =~ "Categoria criada com sucesso!"
      assert html =~ "unique category name"
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

    test "deletes category in listing", %{conn: conn, category: category} do
      {:ok, index_live, _html} = live(conn, ~p"/categories")

      assert index_live
             |> element("#categories-#{category.id} button[phx-click='confirm_delete']")
             |> render_click()

      assert index_live |> element("button", "Sim, Apagar") |> render_click()
      refute has_element?(index_live, "#categories-#{category.id}")
    end
  end

  describe "Show" do
    setup [:create_category]

    test "displays category", %{conn: conn, category: category} do
      {:ok, _show_live, html} = live(conn, ~p"/categories/#{category}")

      assert html =~ "Categoria:"
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
