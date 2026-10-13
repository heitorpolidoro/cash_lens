defmodule CashLensWeb.SecurityHeadersTest do
  use CashLensWeb.ConnCase, async: true

  @moduletag :logged_out

  describe "browser response headers" do
    test "the login page carries a strict Content-Security-Policy", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "default-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "form-action 'self'"
      assert csp =~ "connect-src 'self'"
      refute csp =~ "unsafe-eval"
      refute csp =~ ~r/script-src[^;]*unsafe-inline/
    end

    test "the login page carries the other secure headers", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [_] = get_resp_header(conn, "referrer-policy")
      assert [permissions] = get_resp_header(conn, "permissions-policy")
      assert permissions =~ "camera=()"
    end

    test "the inline script carries the per-request nonce from the CSP", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      [csp] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/script-src[^;]*'nonce-([^']+)'/, csp)

      html = html_response(conn, 200)
      assert html =~ ~s(nonce="#{nonce}")
      refute html =~ ~r/<script>/

      other = conn |> recycle() |> get(~p"/users/log_in")
      [other_csp] = get_resp_header(other, "content-security-policy")
      refute other_csp =~ nonce
    end
  end

  describe "CSRF protection" do
    # Phoenix.ConnTest skips CSRF by default; these requests behave like a
    # browser that sends no token.
    defp browser_post(conn, method, path, params \\ %{}) do
      conn
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
      |> dispatch(@endpoint, method, path, params)
    end

    test "POST /users/register without a token answers 403", %{conn: conn} do
      assert_error_sent 403, fn ->
        browser_post(conn, :post, ~p"/users/register", %{
          "user" => %{"email" => "a@b.co", "password" => "correct horse battery"}
        })
      end
    end

    test "POST /users/log_in without a token answers 403", %{conn: conn} do
      assert_error_sent 403, fn ->
        browser_post(conn, :post, ~p"/users/log_in", %{
          "user" => %{"email" => "a@b.co", "password" => "x"}
        })
      end
    end

    test "DELETE /users/log_out without a token answers 403", %{conn: conn} do
      assert_error_sent 403, fn -> browser_post(conn, :delete, ~p"/users/log_out") end
    end

    @tag logged_out: false
    test "the session-based API rejects an unsafe verb without a token", %{conn: conn} do
      assert_error_sent 403, fn ->
        browser_post(conn, :delete, "/api/accounts/#{Ecto.UUID.generate()}")
      end
    end

    @tag logged_out: false
    test "the session-based API accepts an unsafe verb with the token header", %{conn: conn} do
      token = Plug.CSRFProtection.get_csrf_token()
      session_token = Plug.CSRFProtection.dump_state()

      conn =
        conn
        |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
        |> Plug.Test.init_test_session(%{"_csrf_token" => session_token})
        |> put_req_header("x-csrf-token", token)
        |> delete("/api/accounts/#{Ecto.UUID.generate()}")

      refute conn.status == 403
    end
  end
end
