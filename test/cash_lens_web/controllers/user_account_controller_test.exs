defmodule CashLensWeb.UserAccountControllerTest do
  use CashLensWeb.ConnCase, async: true

  import CashLens.UsersFixtures
  import Ecto.Query

  alias CashLens.Audit
  alias CashLens.Audit.LoginAttempt
  alias CashLens.Repo
  alias CashLens.Users
  alias CashLens.Users.User
  alias CashLens.Users.UserToken

  test "GET /account shows the export link and the delete warning", %{conn: conn} do
    html = html_response(get(conn, ~p"/account"), 200)
    assert html =~ "/account/export"
    assert html =~ "delete-warning"
    assert html =~ ~s(id="sidebar-toggle")
  end

  test "GET /account requires login" do
    assert redirected_to(get(build_conn(), ~p"/account")) == ~p"/users/log_in"
    assert redirected_to(get(build_conn(), ~p"/account/export")) == ~p"/users/log_in"
    assert redirected_to(delete(build_conn(), ~p"/account")) == ~p"/users/log_in"
  end

  test "export is an attachment with the user's data, no hashes, no other users", %{
    conn: conn,
    user: user
  } do
    other = user_fixture()
    Audit.record_login_attempt(user, user.email, true, "9.9.9.9")
    Audit.record_login_attempt(other, other.email, true, "8.8.8.8")

    conn = get(conn, ~p"/account/export")
    assert response(conn, 200)
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"

    body = Jason.decode!(conn.resp_body)
    assert [%{"email" => email}] = body["users"]
    assert email == user.email
    assert [%{"ip" => "9.9.9.9"}] = body["login_attempts"]
    refute conn.resp_body =~ "hashed_password"
    refute conn.resp_body =~ user.hashed_password
    refute conn.resp_body =~ other.email
  end

  test "delete with the right password removes everything and clears the session", %{
    conn: conn,
    user: user
  } do
    Audit.record_login_attempt(user, user.email, true, "9.9.9.9")
    Users.deliver_reset_password_instructions(user, &("http://x/" <> &1))

    deleted = delete(conn, ~p"/account", account: %{password: valid_user_password()})
    assert redirected_to(deleted) == ~p"/users/log_in"

    refute Repo.get(User, user.id)
    assert Repo.all(from t in UserToken, where: t.user_id == ^user.id) == []
    assert Repo.all(from a in LoginAttempt, where: a.email == ^user.email) == []

    assert deleted |> recycle() |> get(~p"/") |> redirected_to() == ~p"/users/log_in"
  end

  test "delete with a wrong or missing password changes nothing", %{conn: conn, user: user} do
    wrong = delete(conn, ~p"/account", account: %{password: "nope-nope-nope"})
    assert redirected_to(wrong) == ~p"/account"
    assert Phoenix.Flash.get(wrong.assigns.flash, :error) =~ "Wrong password"

    missing = delete(conn, ~p"/account", %{})
    assert redirected_to(missing) == ~p"/account"
    assert Repo.get(User, user.id)
  end
end
