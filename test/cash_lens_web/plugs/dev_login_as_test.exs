defmodule CashLensWeb.Plugs.DevLoginAsTest do
  use CashLensWeb.ConnCase, async: false

  @moduletag :logged_out

  import CashLens.UsersFixtures

  alias CashLensWeb.Plugs.DevLoginAs

  defp session_conn(conn), do: conn |> Plug.Test.init_test_session(%{})

  test "is compiled as a no-op outside dev, whatever the environment holds", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    System.put_env("CASH_LENS_DEV_LOGIN_AS", user.email)
    on_exit(fn -> System.delete_env("CASH_LENS_DEV_LOGIN_AS") end)

    conn = conn |> session_conn() |> DevLoginAs.call([])
    assert get_session(conn, :user_id) == nil
  end

  test "signs in the enabled user with that email", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    conn = conn |> session_conn() |> DevLoginAs.log_in_as(user.email)
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :session_nonce) == user.session_nonce
  end

  test "leaves a disabled or unknown user, or an existing session, alone", %{conn: conn} do
    disabled = user_fixture()

    assert conn |> session_conn() |> DevLoginAs.log_in_as(disabled.email) |> get_session(:user_id) ==
             nil

    assert conn
           |> session_conn()
           |> DevLoginAs.log_in_as("nobody@example.com")
           |> get_session(:user_id) == nil

    assert conn |> session_conn() |> DevLoginAs.log_in_as(nil) |> get_session(:user_id) == nil

    other = user_fixture(%{enabled: true})

    conn =
      conn |> Plug.Test.init_test_session(%{user_id: "kept"}) |> DevLoginAs.log_in_as(other.email)

    assert get_session(conn, :user_id) == "kept"
  end
end
