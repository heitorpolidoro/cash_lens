defmodule CashLensWeb.LayoutsTest do
  use CashLensWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias CashLensWeb.Layouts

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
    # App layout usually takes assigns and a @inner_content
    # Since it's embedded, we can try to call it if it's public (it usually isn't)
    # But we can test it via a controller test or by calling render(Layouts, "app", assigns)
    html =
      Phoenix.Template.render_to_string(Layouts, "app", "html", %{
        flash: %{},
        inner_content: "Content",
        page_title: "Title",
        conn: build_conn()
      })

    assert html =~ "Content"
    assert html =~ "CashLens"
  end
end
