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
    assert redirected_to(conn) == ~p"/users/log_in"
    refute get_session(conn, :user_id)
    refute user.confirmed_at
  end

  test "register page links to the privacy notice", %{conn: conn} do
    assert html_response(get(conn, ~p"/users/register"), 200) =~ ~s(href="/privacy")
  end

  test "registering delivers exactly one confirmation email with a link", %{conn: conn} do
    email = unique_user_email()
    post(conn, ~p"/users/register", user: %{email: email, password: "plain-password-123"})

    assert_received {:email, %Swoosh.Email{to: [{_, ^email}]} = mail}
    assert mail.text_body =~ "/users/confirm/"
    refute_received {:email, _}
  end

  test "invalid POST re-renders with errors", %{conn: conn} do
    conn = post(conn, ~p"/users/register", user: %{email: "bad", password: "short"})
    assert html_response(conn, 200) =~ "must have the @ sign"
    refute Users.get_user_by_email("bad")
  end

  test "a common password re-renders the form with the error", %{conn: conn} do
    conn =
      post(conn, ~p"/users/register",
        user: %{email: unique_user_email(), password: "qwertyuiop12"}
      )

    assert html_response(conn, 200) =~ "is too common"
  end

  test "a password equal to the email local part is refused on the form", %{conn: conn} do
    conn =
      post(conn, ~p"/users/register",
        user: %{email: "marianaoliveira@example.com", password: "marianaoliveira"}
      )

    assert html_response(conn, 200) =~ "is too similar to your email"
    refute Users.get_user_by_email("marianaoliveira@example.com")
  end
end
