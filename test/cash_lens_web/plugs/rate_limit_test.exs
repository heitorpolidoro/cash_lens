defmodule CashLensWeb.Plugs.RateLimitTest do
  # Changes application env and shares one ETS table.
  use CashLensWeb.ConnCase, async: false

  @moduletag :logged_out

  alias CashLensWeb.Plugs.RateLimit

  @key CashLensWeb.Plugs.RateLimit

  setup do
    original = Application.get_env(:cash_lens, @key)

    Application.put_env(
      :cash_lens,
      @key,
      Keyword.merge(original,
        login: [limit: 3, window_seconds: 60],
        register: [limit: 2, window_seconds: 3600]
      )
    )

    RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:cash_lens, @key, original)
      RateLimit.reset()
    end)
  end

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp login(conn, ip, email) do
    conn |> from_ip(ip) |> post(~p"/users/log_in", user: %{email: email, password: "wrong"})
  end

  defp register(conn, ip, n) do
    conn
    |> from_ip(ip)
    |> post(~p"/users/register", user: %{email: "user#{n}@example.com", password: "short"})
  end

  test "login attempts 1..N pass and N+1 answers 429 with retry-after", %{conn: conn} do
    for i <- 1..3 do
      assert login(conn, {10, 0, 0, 1}, "u#{i}@example.com").status == 401
    end

    limited = login(conn, {10, 0, 0, 1}, "u4@example.com")
    assert limited.status == 429
    [retry_after] = get_resp_header(limited, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end

  test "register attempts 1..N pass and N+1 answers 429 with retry-after", %{conn: conn} do
    for i <- 1..2, do: assert(register(conn, {10, 0, 0, 1}, i).status == 200)

    limited = register(conn, {10, 0, 0, 1}, 3)
    assert limited.status == 429
    [retry_after] = get_resp_header(limited, "retry-after")
    assert String.to_integer(retry_after) in 1..3600
  end

  test "a different IP is unaffected", %{conn: conn} do
    for i <- 1..4, do: login(conn, {10, 0, 0, 1}, "u#{i}@example.com")

    assert login(conn, {10, 0, 0, 1}, "x@example.com").status == 429
    assert login(conn, {10, 0, 0, 2}, "x@example.com").status == 401
  end

  test "login is also limited per submitted email across IPs", %{conn: conn} do
    for i <- 1..3, do: assert(login(conn, {10, 0, 1, i}, "Victim@Example.com").status == 401)

    assert login(conn, {10, 0, 1, 99}, "victim@example.com").status == 429
    assert login(conn, {10, 0, 1, 99}, "other@example.com").status == 401
  end

  test "GET requests are never limited", %{conn: conn} do
    for _ <- 1..10 do
      assert conn |> from_ip({10, 0, 0, 1}) |> get(~p"/users/log_in") |> Map.fetch!(:status) ==
               200
    end
  end

  test "the sweep drops expired counters and keeps live ones" do
    :ets.insert(RateLimit, {{:login, {:ip, "old"}, 1}, 5, 1})
    live = System.system_time(:second) + 100
    :ets.insert(RateLimit, {{:login, {:ip, "live"}, 2}, 5, live})

    send(RateLimit.Store, :sweep)
    :sys.get_state(RateLimit.Store)

    assert :ets.lookup(RateLimit, {:login, {:ip, "old"}, 1}) == []
    assert [_] = :ets.lookup(RateLimit, {:login, {:ip, "live"}, 2})
  end

  describe "client IP" do
    test "x-forwarded-for is ignored unless the proxy is trusted", %{conn: conn} do
      for i <- 1..3 do
        conn
        |> from_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.#{i}")
        |> post(~p"/users/log_in", user: %{email: "u#{i}@example.com", password: "wrong"})
      end

      limited =
        conn
        |> from_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.50")
        |> post(~p"/users/log_in", user: %{email: "u9@example.com", password: "wrong"})

      assert limited.status == 429
    end

    test "when the proxy is trusted the last x-forwarded-for entry is the client", %{conn: conn} do
      current = Application.get_env(:cash_lens, @key)
      Application.put_env(:cash_lens, @key, Keyword.put(current, :trust_proxy_headers, true))

      post_as = fn forwarded, n ->
        conn
        |> from_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", forwarded)
        |> post(~p"/users/log_in", user: %{email: "u#{n}@example.com", password: "wrong"})
      end

      for n <- 1..3, do: assert(post_as.("1.1.1.1, 203.0.113.7", n).status == 401)

      assert post_as.("2.2.2.2, 203.0.113.7", 4).status == 429
      assert post_as.("2.2.2.2, 203.0.113.8", 5).status == 401
    end
  end
end
