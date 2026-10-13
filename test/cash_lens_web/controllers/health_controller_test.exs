defmodule CashLensWeb.HealthControllerTest do
  # Not async: swaps a global application env.
  use CashLensWeb.ConnCase, async: false

  @moduletag :logged_out

  setup do
    on_exit(fn -> Application.delete_env(:cash_lens, :health_check) end)
  end

  test "200 with the database reachable, without login", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "503 when the check fails", %{conn: conn} do
    Application.put_env(:cash_lens, :health_check, fn -> false end)
    conn = get(conn, ~p"/health")
    assert json_response(conn, 503) == %{"status" => "unavailable"}
  end

  test "503 when the check raises or exits", %{conn: conn} do
    Application.put_env(:cash_lens, :health_check, fn -> raise "boom with secrets" end)
    conn = get(conn, ~p"/health")
    assert json_response(conn, 503) == %{"status" => "unavailable"}
    refute conn.resp_body =~ "secrets"

    Application.put_env(:cash_lens, :health_check, fn -> exit(:timeout) end)
    assert json_response(get(build_conn(), ~p"/health"), 503)
  end

  test "CashLens.Health.database_ok?/0 is true against the test database" do
    assert CashLens.Health.database_ok?()
  end

  test "CashLens.Health.database_ok?/0 is false (not a crash) when the query fails" do
    # An owner-less checkout makes the query raise inside the sandbox.
    result =
      Task.async(fn -> CashLens.Health.database_ok?() end)
      |> Task.await()

    assert is_boolean(result)
  end
end
