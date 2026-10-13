defmodule CashLensWeb.UserSessionControllerTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  import CashLens.UsersFixtures

  defp log_in(conn, user) do
    post(conn, ~p"/users/log_in", user: %{email: user.email, password: valid_user_password()})
  end

  test "GET /users/log_in renders the form", %{conn: conn} do
    assert html_response(get(conn, ~p"/users/log_in"), 200) =~ "Entrar"
  end

  test "enabled user logs in and lands on /", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    conn = log_in(conn, user)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
  end

  test "wrong password shows the generic error and no session", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    conn = post(conn, ~p"/users/log_in", user: %{email: user.email, password: "wrong-password"})

    assert html_response(conn, 401) =~ "Invalid email or password"
    refute get_session(conn, :user_id)
  end

  test "unknown email gives the same message", %{conn: conn} do
    conn = post(conn, ~p"/users/log_in", user: %{email: "no@one.com", password: "whatever-12345"})
    assert html_response(conn, 401) =~ "Invalid email or password"
  end

  test "malformed params give the same message", %{conn: conn} do
    conn = post(conn, ~p"/users/log_in", %{})
    assert html_response(conn, 401) =~ "Invalid email or password"
  end

  test "a logged-in user is bounced away from the login page", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    conn = conn |> log_in_user(user) |> get(~p"/users/log_in")
    assert redirected_to(conn) == ~p"/"
  end

  test "logout clears the session and replaying the old cookie redirects to login", %{
    conn: conn
  } do
    user = user_fixture(%{enabled: true})
    logged_in = log_in(conn, user)

    old_cookie = logged_in.resp_cookies["_cash_lens_key"].value
    assert logged_in |> recycle() |> get(~p"/") |> html_response(200)

    out = logged_in |> recycle() |> delete(~p"/users/log_out")
    assert redirected_to(out) == ~p"/users/log_in"

    # The cookie issued before logout is a signed, stateless blob: only the
    # nonce rotation stops it from working.
    replay =
      build_conn()
      |> Plug.Test.put_req_cookie("_cash_lens_key", old_cookie)
      |> get(~p"/")

    assert redirected_to(replay) == ~p"/users/log_in"

    # And the cookie the logout response left behind is empty too.
    assert out |> recycle() |> get(~p"/") |> redirected_to() == ~p"/users/log_in"
  end
end
