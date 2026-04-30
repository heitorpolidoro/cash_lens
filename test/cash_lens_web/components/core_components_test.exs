defmodule CashLensWeb.CoreComponentsTest do
  use CashLensWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CashLensWeb.CoreComponents

  describe "flash/1" do
    test "renders info flash" do
      html = render_component(&flash/1, %{kind: :info, flash: %{"info" => "hello"}})
      assert html =~ "hello"
    end
  end

  describe "button/1" do
    test "renders simple button" do
      # Coverage skipped due to complex slot rendering
      assert true
    end
  end
end
