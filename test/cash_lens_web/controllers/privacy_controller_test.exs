defmodule CashLensWeb.PrivacyControllerTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  test "GET /privacy is public", %{conn: conn} do
    html = html_response(get(conn, ~p"/privacy"), 200)
    assert html =~ "Aviso de privacidade"
    assert html =~ "LGPD"
  end

  test "the login and register pages link to it", %{conn: conn} do
    for path <- [~p"/users/log_in", ~p"/users/register"] do
      assert conn |> get(path) |> html_response(200) =~ ~s(href="/privacy")
    end
  end
end

defmodule CashLensWeb.PrivacyLoggedInTest do
  use CashLensWeb.ConnCase, async: true

  test "the app footer links to the privacy notice", %{conn: conn} do
    assert conn |> get(~p"/") |> html_response(200) =~ ~s(href="/privacy")
  end
end
