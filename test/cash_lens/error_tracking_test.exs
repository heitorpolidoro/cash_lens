defmodule CashLens.ErrorTrackingTest do
  # Not async: Sentry.Test collection and the runtime config are global.
  use CashLensWeb.ConnCase, async: false

  import Sentry.Test

  test "no DSN is configured in test (nothing is sent)" do
    assert Sentry.Config.dsn() == nil
    assert Application.get_env(:sentry, :dsn) == nil
  end

  test "dev and base config never set a DSN" do
    refute Keyword.get(Config.Reader.read!("config/dev.exs", env: :dev)[:sentry] || [], :dsn)
  end

  test "runtime config enables Sentry in prod only when SENTRY_DSN is set" do
    env = %{
      "DATABASE_URL" => "ecto://u:p@localhost/db",
      "MIGRATION_DATABASE_URL" => "ecto://o:p@localhost/db",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "MAILGUN_API_KEY" => "key",
      "MAILGUN_DOMAIN" => "mg.example.com"
    }

    read = fn extra ->
      for {k, v} <- Map.merge(env, extra), do: System.put_env(k, v)
      on_exit(fn -> for {k, _} <- Map.merge(env, extra), do: System.delete_env(k) end)
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end

    with_dsn = read.(%{"SENTRY_DSN" => "https://public@sentry.example.com/1"})
    assert with_dsn[:sentry][:dsn] == "https://public@sentry.example.com/1"
    assert with_dsn[:cash_lens][CashLens.Mailer][:adapter] == Swoosh.Adapters.Mailgun

    System.delete_env("SENTRY_DSN")
    without = read.(%{})
    assert without[:sentry] == nil

    dev = Config.Reader.read!("config/runtime.exs", env: :dev)
    assert dev[:sentry] == nil
  end

  # Runs as the default logged-in user so the API request is authorised.
  test "an unhandled controller error is captured", %{conn: conn} do
    start_collecting_sentry_reports()

    # A malformed UUID raises Ecto.Query.CastError, which the API controller does
    # not rescue, so it reaches Sentry.PlugCapture around the router.
    assert_raise Ecto.Query.CastError, fn ->
      conn |> put_req_header("accept", "application/json") |> get("/api/accounts/not-a-uuid")
    end

    assert [%Sentry.Event{} = event] = pop_sentry_reports()
    assert hd(event.exception).type == "Ecto.Query.CastError"
  end
end
