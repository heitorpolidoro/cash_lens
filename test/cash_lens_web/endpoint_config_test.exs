defmodule CashLensWeb.EndpointConfigTest do
  # Mutates the process environment (SECRET_KEY_BASE, DATABASE_URL).
  use ExUnit.Case, async: false

  @endpoint_key CashLensWeb.Endpoint

  defp prod_app_config do
    "config/config.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> Keyword.fetch!(:cash_lens)
  end

  defp prod_config, do: Keyword.fetch!(prod_app_config(), @endpoint_key)

  defp read_runtime(env_overrides) do
    originals = Map.new(env_overrides, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env_overrides, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    after
      Enum.each(originals, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  test "the prod session cookie is secure, http-only and same-site Lax" do
    session = Keyword.fetch!(prod_config(), :session_options)

    assert session[:secure] == true
    assert session[:http_only] == true
    assert session[:same_site] == "Lax"
    assert session[:encryption_salt]
    assert session[:signing_salt]
  end

  test "the session options are not hardcoded in the endpoint" do
    refute File.read!("lib/cash_lens_web/endpoint.ex") =~ "signing_salt:"
  end

  test "prod forces SSL with an explicit HSTS" do
    force_ssl = Keyword.fetch!(prod_config(), :force_ssl)

    assert force_ssl[:hsts] == true
    assert force_ssl[:expires] >= 31_536_000
    assert force_ssl[:rewrite_on] == [:x_forwarded_proto]
  end

  test "prod trusts the proxy header for the client IP" do
    rate_limit = Keyword.fetch!(prod_app_config(), CashLensWeb.Plugs.RateLimit)
    assert rate_limit[:trust_proxy_headers] == true
  end

  test "config/prod.exs and config/config.exs contain no secret or credential literal" do
    secret_literal =
      ~r/(secret_key_base|password|passwd|api_key|apikey|secret|token|database_url|url)\s*(:|=>|=)\s*"[^"]{6,}"/i

    for file <- ["config/prod.exs", "config/config.exs"] do
      code =
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      refute Regex.match?(secret_literal, code), "#{file} contains a secret-looking literal"
    end
  end

  test "the prod runtime config reads the secrets from the environment" do
    config =
      read_runtime([
        {"SECRET_KEY_BASE", String.duplicate("a", 64)},
        {"DATABASE_URL", "ecto://u:p@localhost/db"},
        {"PHX_HOST", "money.example.org"},
        {"MAILGUN_API_KEY", "key-for-test"},
        {"MAILGUN_DOMAIN", "mg.example.org"}
      ])

    endpoint = config |> Keyword.fetch!(:cash_lens) |> Keyword.fetch!(@endpoint_key)
    assert endpoint[:secret_key_base] == String.duplicate("a", 64)
    assert endpoint[:check_origin] == ["https://money.example.org"]
  end

  test "evaluating runtime.exs for prod raises when SECRET_KEY_BASE is unset" do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn ->
      read_runtime([{"SECRET_KEY_BASE", nil}, {"DATABASE_URL", "ecto://u:p@localhost/db"}])
    end
  end

  test "evaluating runtime.exs for prod raises when DATABASE_URL is unset" do
    assert_raise RuntimeError, ~r/DATABASE_URL/, fn ->
      read_runtime([{"SECRET_KEY_BASE", String.duplicate("a", 64)}, {"DATABASE_URL", nil}])
    end
  end
end
