defmodule CashLensWeb.LayoutsTest do
  use CashLensWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias CashLensWeb.Layouts

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp render_app(assigns) do
    Phoenix.Template.render_to_string(
      Layouts,
      "app",
      "html",
      Map.merge(%{flash: %{}, inner_content: "Content", page_title: "Title"}, assigns)
    )
  end

  test "renders flash_group" do
    html =
      render_component(&Layouts.flash_group/1, %{flash: %{"info" => "info!", "error" => "err!"}})

    assert html =~ "info!"
    assert html =~ "err!"
  end

  test "renders theme_toggle" do
    html = render_component(&Layouts.theme_toggle/1, %{})
    assert html =~ "hero-sun"
    assert html =~ "hero-moon"
  end

  test "renders app layout" do
    html = render_app(%{conn: build_conn()})

    assert html =~ "Content"
    assert html =~ "CashLens"
  end

  describe "nav_groups/1" do
    test "organizes navigation in the four semantic groups, in order" do
      assert Enum.map(Layouts.nav_groups(), & &1.title) == [
               "Visão Geral",
               "Conciliação & Importação",
               "Planejamento",
               "Cadastros & Sistema"
             ]
    end

    test "every navigation target resolves to a real route (no dead links)" do
      for group <- Layouts.nav_groups(), item <- group.items do
        assert %{} = Phoenix.Router.route_info(CashLensWeb.Router, "GET", item.path, "localhost"),
               "#{item.label} points at #{item.path}, which matches no route"
      end
    end

    test "maps every navigable screen exactly once" do
      paths = for group <- Layouts.nav_groups(), item <- group.items, do: item.path

      assert paths == Enum.uniq(paths)
      assert length(paths) == 16
    end

    test "the monthly closing entry points at the current competência" do
      today = ~D[2026-09-15]

      item =
        Layouts.nav_groups(today)
        |> Enum.flat_map(& &1.items)
        |> Enum.find(&(&1.match_prefix == "/months"))

      assert item.path == "/months/2026/9"
    end
  end

  describe "sidebar" do
    test "renders the four group titles and every screen label" do
      html = render_app(%{current_path: "/"})

      for group <- Layouts.nav_groups() do
        assert html =~ esc(group.title)

        for item <- group.items do
          assert html =~ esc(item.label)
          assert html =~ ~s(href="#{item.path}")
        end
      end
    end

    test "highlights the active route and leaves the others unhighlighted" do
      html = render_app(%{current_path: "/balances"})

      assert html =~ ~r{<a[^>]+href="/balances"[^>]*class="[^"]*bg-blue-50[^"]*text-blue-600}

      refute html =~ ~r{<a[^>]+href="/accounts"[^>]*class="[^"]*bg-blue-50}
    end

    test "highlights a nested route through its section prefix" do
      html = render_app(%{current_path: "/accounts/new"})

      assert html =~ ~r{<a[^>]+href="/accounts"[^>]*class="[^"]*bg-blue-50}
    end

    test "the dashboard entry is only active on an exact match" do
      html = render_app(%{current_path: "/balances"})

      refute html =~ ~r{<a[^>]+href="/"[^>]*class="[^"]*bg-blue-50}
    end

    test "offers a collapse toggle for the icons-only compact mode" do
      html = render_app(%{current_path: "/"})

      assert html =~ ~s(id="sidebar-toggle")
      assert html =~ "Recolher menu"
      assert html =~ ~s(aria-expanded="true")
      assert html =~ "menu-label"
      assert html =~ "section-title"
    end

    test "every entry carries a native tooltip so compact mode stays readable" do
      html = render_app(%{current_path: "/"})

      for group <- Layouts.nav_groups(), item <- group.items do
        assert html =~ ~s(title="#{esc(item.label)}")
      end
    end
  end

  describe "topbar" do
    test "renders the global quick actions" do
      html = render_app(%{current_path: "/"})

      assert html =~ "Importar Extratos"
      assert html =~ ~s(href="/transactions?open_import=true")
      assert html =~ "Nova Transação"
      assert html =~ ~s(href="/transactions/new")
    end

    test "renders the breadcrumb of the active group and screen" do
      html = render_app(%{current_path: "/statements"})

      assert html =~ "Conciliação &amp; Importação"
      assert html =~ "Faturas de Cartão"
    end

    test "falls back to the app name when the path maps to no menu entry" do
      html = render_app(%{current_path: "/some/unmapped/path"})

      assert html =~ "CashLens"
    end

    test "shows the accounting reference month" do
      today = Date.utc_today()
      html = render_app(%{current_path: "/"})

      assert html =~ "#{CashLensWeb.Formatters.month_name(today.month)} / #{today.year}"
    end
  end

  describe "light theme" do
    test "uses the light palette shared with the redesigned screens" do
      html = render_app(%{current_path: "/"})

      assert html =~ "bg-[#f8fafc]"
      assert html =~ "border-slate-200"
    end

    test "drops the DaisyUI theme-dependent base classes from the layout chrome" do
      html = render_app(%{current_path: "/"})

      refute html =~ "bg-base-"
      refute html =~ "text-base-content"
      refute html =~ "border-base-"
    end
  end

  describe "current path resolution" do
    test "falls back to the conn request path when there is no live assign" do
      conn = %{build_conn() | request_path: "/categories"}
      html = render_app(%{conn: conn})

      assert html =~ ~r{<a[^>]+href="/categories"[^>]*class="[^"]*bg-blue-50}
    end
  end
end
