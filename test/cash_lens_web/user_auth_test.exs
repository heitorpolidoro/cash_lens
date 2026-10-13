defmodule CashLensWeb.UserAuthTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  alias CashLens.Repo
  import CashLens.UsersFixtures

  describe "logged out" do
    for path <- ["/", "/accounts", "/credit_card_links", "/admin/exclusion_rules", "/forecast"] do
      test "GET #{path} redirects to the login page", %{conn: conn} do
        conn = get(conn, unquote(path))
        assert redirected_to(conn, 302) == "/users/log_in"
      end
    end

    test "the pending page needs a session", %{conn: conn} do
      assert conn |> get(~p"/users/pending") |> redirected_to() == "/users/log_in"
    end

    test "/api/accounts answers 401 JSON", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/accounts")
      assert json_response(conn, 401)
    end

    test "a session for a deleted user counts as logged out", %{conn: conn} do
      user = user_fixture(%{enabled: true})
      logged = log_in_user(conn, user)
      Repo.delete!(user)
      assert logged |> get(~p"/") |> redirected_to() == "/users/log_in"
    end
  end

  describe "disabled user" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "is sent to the pending page from / and from LiveView routes", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == "/users/pending"
      assert conn |> get(~p"/accounts") |> redirected_to() == "/users/pending"
    end

    test "sees the pending message and never the app", %{conn: conn} do
      html = conn |> get(~p"/users/pending") |> html_response(200)
      assert html =~ "pending approval"
      refute html =~ "Contas"
    end

    test "is rejected from the API", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/accounts")
      assert json_response(conn, 401)
    end

    test "enabling the user lets the next request through", %{conn: conn, user: user} do
      assert conn |> get(~p"/") |> redirected_to() == "/users/pending"
      user |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
      assert conn |> get(~p"/") |> html_response(200)
    end

    test "a LiveView socket is rejected for a disabled user", %{conn: conn} do
      import Phoenix.LiveViewTest

      assert {:error, {:redirect, %{to: "/users/pending"}}} = live(conn, ~p"/accounts")
    end
  end

  describe "enabled user" do
    test "reaches the app and the API", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert conn |> get(~p"/") |> html_response(200)

      api = conn |> put_req_header("accept", "application/json") |> get("/api/accounts")
      assert json_response(api, 200)
    end
  end
end
