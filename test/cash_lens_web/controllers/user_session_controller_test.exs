defmodule CashLensWeb.UserSessionControllerTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  import CashLens.UsersFixtures

  alias CashLens.Audit.LoginAttempt
  alias CashLens.Repo

  defp log_in(conn, user) do
    post(conn, ~p"/users/log_in", user: %{email: user.email, password: valid_user_password()})
  end

  test "GET /users/log_in renders the form", %{conn: conn} do
    html = html_response(get(conn, ~p"/users/log_in"), 200)
    assert html =~ "Entrar"
    assert html =~ ~s(href="/privacy")
    assert html =~ ~s(href="/users/reset_password")
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

  describe "email confirmation" do
    test "an unconfirmed user is refused, then can log in after using the link", %{conn: conn} do
      email = unique_user_email()
      post(conn, ~p"/users/register", user: %{email: email, password: valid_user_password()})
      assert_received {:email, mail}

      refused =
        post(build_conn(), ~p"/users/log_in",
          user: %{email: email, password: valid_user_password()}
        )

      assert html_response(refused, 401) =~ "Confirm your email"
      refute get_session(refused, :user_id)

      confirm = get(build_conn(), ~p"/users/confirm/#{extract_token(mail)}")
      assert redirected_to(confirm) == ~p"/users/log_in"

      ok =
        post(build_conn(), ~p"/users/log_in",
          user: %{email: email, password: valid_user_password()}
        )

      assert get_session(ok, :user_id)
    end

    test "an unconfirmed user with a wrong password gets the generic message", %{conn: conn} do
      user = user_fixture(%{confirmed: false})
      conn = post(conn, ~p"/users/log_in", user: %{email: user.email, password: "wrong-password"})
      assert html_response(conn, 401) =~ "Invalid email or password"
    end

    test "a reused or garbage confirm link is refused", %{conn: conn} do
      user = user_fixture(%{confirmed: false})
      {:ok, mail} = CashLens.Users.deliver_confirmation_instructions(user, &("http://x/" <> &1))
      token = extract_token(mail)

      first = get(conn, ~p"/users/confirm/#{token}")
      assert Phoenix.Flash.get(first.assigns.flash, :info) =~ "Email confirmed"
      reused = get(build_conn(), ~p"/users/confirm/#{token}")
      assert Phoenix.Flash.get(reused.assigns.flash, :error) =~ "invalid or has expired"
      bad = get(build_conn(), ~p"/users/confirm/garbage")
      assert Phoenix.Flash.get(bad.assigns.flash, :error) =~ "invalid or has expired"
    end

    test "resend delivers one email for an unconfirmed user and answers the same otherwise", %{
      conn: conn
    } do
      user = user_fixture(%{confirmed: false})
      assert html_response(get(conn, ~p"/users/confirm"), 200) =~ "Reenviar"

      known = post(conn, ~p"/users/confirm", user: %{email: user.email})
      assert_received {:email, _}
      unknown = post(build_conn(), ~p"/users/confirm", user: %{email: "nobody@example.com"})
      refute_received {:email, _}
      malformed = post(build_conn(), ~p"/users/confirm", %{})

      messages =
        for c <- [known, unknown, malformed], do: Phoenix.Flash.get(c.assigns.flash, :info)

      assert [m] = Enum.uniq(messages)
      assert is_binary(m)
    end
  end

  describe "login audit" do
    defp attempts, do: Repo.all(LoginAttempt)

    test "a successful login adds one row with user, ip and timestamp", %{conn: conn} do
      user = user_fixture(%{enabled: true})
      log_in(conn, user)

      assert [a] = attempts()
      assert a.user_id == user.id
      assert a.success
      assert a.email == user.email
      assert a.ip == "127.0.0.1"
      assert a.inserted_at
    end

    test "a wrong password adds a failed row without storing the password", %{conn: conn} do
      user = user_fixture(%{enabled: true})
      post(conn, ~p"/users/log_in", user: %{email: user.email, password: "wrong-password-xyz"})

      assert [a] = attempts()
      assert a.user_id == user.id
      refute a.success
      refute inspect(a) =~ "wrong-password-xyz"
    end

    test "an unknown email adds a row with a nil user", %{conn: conn} do
      post(conn, ~p"/users/log_in",
        user: %{email: "ghost@example.com", password: "whatever-12345"}
      )

      assert [a] = attempts()
      assert a.user_id == nil
      refute a.success
      assert a.email == "ghost@example.com"
      assert a.ip != ""
    end

    test "an unconfirmed login with the right password is recorded as a failure", %{conn: conn} do
      user = user_fixture(%{confirmed: false})
      log_in(conn, user)
      assert [%{success: false, user_id: user_id}] = attempts()
      assert user_id == user.id
    end
  end
end
