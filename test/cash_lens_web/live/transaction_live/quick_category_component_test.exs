defmodule CashLensWeb.TransactionLive.QuickCategoryComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.CategoriesFixtures

  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLensWeb.TransactionLive.QuickCategoryComponent
  alias Ecto.Adapters.SQL.Sandbox

  defmodule HostLive do
    use Phoenix.LiveView
    import CashLensWeb.CoreComponents
    alias CashLens.Categories
    alias CashLens.Categories.Category

    def mount(_params, _session, socket) do
      form = Phoenix.Component.to_form(Categories.change_category(%Category{}))

      {:ok,
       assign(socket,
         show: true,
         category_form: form,
         categories: Categories.list_categories(),
         target_transaction_id: "some-tx-id"
       )}
    end

    def handle_info({:category_created, _category, _tx_id}, socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, :info, "Category created!")}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <.live_component
        module={QuickCategoryComponent}
        id="quick-category"
        show={@show}
        category_form={@category_form}
        categories={@categories}
        target_transaction_id={@target_transaction_id}
      />
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      """
    end
  end

  setup do
    Sandbox.mode(CashLens.Repo, {:shared, self()})
    :ok
  end

  test "renders the modal", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, HostLive)
    assert html =~ "Nova Categoria"
    assert html =~ "Salvar Categoria"
  end

  test "renders parent category options when categories exist", %{conn: conn} do
    parent = category_fixture()
    {:ok, _view, html} = live_isolated(conn, HostLive)
    assert html =~ parent.name
  end

  test "creates a category without parent", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)

    view
    |> element("#quick-category-form")
    |> render_submit(%{"category" => %{"name" => "My New Category", "parent_id" => ""}})

    assert render(view) =~ "Category created!"
    assert Categories.get_category_by_slug("my-new-category") != nil
  end

  test "validate selects a parent and clear_parent resets it", %{conn: conn} do
    parent = category_fixture(name: "Pai")
    {:ok, view, _html} = live_isolated(conn, HostLive)

    # Validate with no parent selected (empty parent_id) — no parent chip.
    no_parent =
      view
      |> element("#quick-category-form")
      |> render_change(%{"category" => %{"name" => "Filha", "parent_id" => ""}})

    refute no_parent =~ "Limpar pai"

    html =
      view
      |> element("#quick-category-form")
      |> render_change(%{"category" => %{"name" => "Filha", "parent_id" => parent.id}})

    assert html =~ "Limpar pai"

    html = view |> element("button[phx-click='clear_parent']") |> render_click()
    refute html =~ "Limpar pai"
  end

  test "creates a category with a parent", %{conn: conn} do
    parent = category_fixture()
    {:ok, view, _html} = live_isolated(conn, HostLive)

    view
    |> element("#quick-category-form")
    |> render_submit(%{"category" => %{"name" => "Child Category", "parent_id" => parent.id}})

    assert render(view) =~ "Category created!"
  end

  test "handles error when category creation fails with invalid data", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, HostLive)
    count_before = length(Categories.list_categories())

    # Submit with empty name to fail validate_required(:name) — triggers the error branch
    view
    |> element("#quick-category-form")
    |> render_submit(%{"name" => "", "parent_id" => ""})

    assert length(Categories.list_categories()) == count_before
  end
end
