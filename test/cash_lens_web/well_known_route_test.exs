# TODO Review
defmodule CashLensWeb.WellKnownRouteTest do
  use CashLensWeb.ConnCase, async: true

  test "GET /.well-known/appspecific/com.chrome.devtools.json returns JSON", %{conn: conn} do
    conn = get(conn, "/.well-known/appspecific/com.chrome.devtools.json")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
    assert conn.resp_body =~ "\"status\":\"ok\""
  end
end
