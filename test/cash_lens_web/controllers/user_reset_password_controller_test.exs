defmodule CashLensWeb.UserResetPasswordControllerTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  import CashLens.UsersFixtures

  alias CashLens.Repo
  alias CashLens.Users
  alias CashLens.Users.UserToken

  defp info(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)

  defp request_reset(conn, email) do
    post(conn, ~p"/users/reset_password", user: %{email: email})
  end

  test "the request form renders", %{conn: conn} do
    assert html_response(get(conn, ~p"/users/reset_password"), 200) =~ "Redefinir senha"
  end

  test "known and unknown emails get the same answer; only the known one gets mail", %{conn: conn} do
    user = user_fixture()
    known = request_reset(conn, user.email)
    assert_received {:email, mail}
    assert mail.text_body =~ "/users/reset_password/"
    unknown = request_reset(build_conn(), "nobody@example.com")
    refute_received {:email, _}
    malformed = post(build_conn(), ~p"/users/reset_password", %{})

    assert redirected_to(known) == ~p"/users/log_in"
    assert info(known) == info(unknown)
    assert info(known) == info(malformed)
  end

  test "the link sets a new password once; the old one stops working", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    request_reset(conn, user.email)
    assert_received {:email, mail}
    token = extract_token(mail)

    assert html_response(get(build_conn(), ~p"/users/reset_password/#{token}"), 200) =~
             "Nova senha"

    done =
      put(build_conn(), ~p"/users/reset_password/#{token}",
        user: %{password: "brand-new-password-1"}
      )

    assert redirected_to(done) == ~p"/users/log_in"

    assert Users.get_user_by_email_and_password(user.email, "brand-new-password-1")
    refute Users.get_user_by_email_and_password(user.email, valid_user_password())

    again =
      put(build_conn(), ~p"/users/reset_password/#{token}",
        user: %{password: "another-new-password-2"}
      )

    assert redirected_to(again) == ~p"/users/log_in"
    assert Phoenix.Flash.get(again.assigns.flash, :error) =~ "invalid or has expired"
    refute Users.get_user_by_email_and_password(user.email, "another-new-password-2")
  end

  test "a weak new password re-renders the form and keeps the token valid", %{conn: conn} do
    user = user_fixture()
    request_reset(conn, user.email)
    assert_received {:email, mail}
    token = extract_token(mail)

    weak = put(build_conn(), ~p"/users/reset_password/#{token}", user: %{password: "short"})
    assert html_response(weak, 200) =~ "should be at least 12"
    assert html_response(get(build_conn(), ~p"/users/reset_password/#{token}"), 200)
  end

  test "missing params re-render the form with errors", %{conn: conn} do
    user = user_fixture()
    request_reset(conn, user.email)
    assert_received {:email, mail}

    conn = put(build_conn(), ~p"/users/reset_password/#{extract_token(mail)}", %{})
    assert html_response(conn, 200) =~ "Nova senha"
  end

  test "an expired token is rejected", %{conn: conn} do
    user = user_fixture()
    request_reset(conn, user.email)
    assert_received {:email, mail}
    past = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
    Repo.update_all(UserToken, set: [inserted_at: past])

    conn = get(build_conn(), ~p"/users/reset_password/#{extract_token(mail)}")
    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
  end

  test "an unknown token is rejected", %{conn: conn} do
    conn = get(conn, ~p"/users/reset_password/nope")
    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
  end

  test "a session from before the reset no longer authenticates", %{conn: conn} do
    user = user_fixture(%{enabled: true})
    old = log_in_user(build_conn(), user)
    assert html_response(get(old, ~p"/"), 200)

    request_reset(conn, user.email)
    assert_received {:email, mail}

    put(build_conn(), ~p"/users/reset_password/#{extract_token(mail)}",
      user: %{password: "brand-new-password-1"}
    )

    assert redirected_to(get(old |> recycle(), ~p"/")) == ~p"/users/log_in"
  end
end
