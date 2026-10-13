defmodule CashLensWeb.UserRegistrationControllerTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  alias CashLens.Users
  import CashLens.UsersFixtures

  test "GET /users/register renders the form", %{conn: conn} do
    assert html_response(get(conn, ~p"/users/register"), 200) =~ "Criar conta"
  end

  test "valid POST creates a disabled user with a hashed password", %{conn: conn} do
    email = unique_user_email()
    conn = post(conn, ~p"/users/register", user: %{email: email, password: "plain-password-123"})

    user = Users.get_user_by_email(email)
    refute user.enabled
    assert user.hashed_password != "plain-password-123"
    assert redirected_to(conn) == ~p"/users/pending"
  end

  test "invalid POST re-renders with errors", %{conn: conn} do
    conn = post(conn, ~p"/users/register", user: %{email: "bad", password: "short"})
    assert html_response(conn, 200) =~ "must have the @ sign"
    refute Users.get_user_by_email("bad")
  end
end
