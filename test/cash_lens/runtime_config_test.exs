defmodule CashLens.RuntimeConfigTest do
  # Mutates the process environment (DATABASE_URL and friends).
  use ExUnit.Case, async: false

  @base_env [
    {"SECRET_KEY_BASE", String.duplicate("a", 64)},
    {"PHX_HOST", "money.example.org"},
    {"MAILGUN_API_KEY", "key-for-test"},
    {"MAILGUN_DOMAIN", "mg.example.org"},
    {"DATABASE_URL", "ecto://cash_lens_app:p@db.example.org/cash_lens"},
    {"MIGRATION_DATABASE_URL", "ecto://owner:p@db-owner.example.org/cash_lens"},
    {"DATABASE_CA_CERT_PATH", nil}
  ]

  defp read_runtime(overrides \\ []) do
    env = Map.merge(Map.new(@base_env), Map.new(overrides))
    originals = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod, target: :host)
      |> Keyword.fetch!(:cash_lens)
    after
      Enum.each(originals, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp repo(config, mod), do: Keyword.fetch!(config, mod)

  for mod <- [CashLens.Repo, CashLens.MigrationRepo] do
    describe inspect(mod) do
      test "uses verified TLS" do
        config = repo(read_runtime(), unquote(mod))

        assert config[:ssl] == true
        assert config[:ssl_opts][:verify] == :verify_peer
        assert config[:ssl_opts][:customize_hostname_check][:match_fun]
      end

      test "falls back to the system CA store without DATABASE_CA_CERT_PATH" do
        ssl_opts = repo(read_runtime(), unquote(mod))[:ssl_opts]

        assert [_ | _] = ssl_opts[:cacerts]
        refute ssl_opts[:cacertfile]
      end

      test "takes the CA from DATABASE_CA_CERT_PATH when set" do
        ssl_opts =
          [{"DATABASE_CA_CERT_PATH", "/etc/ssl/db-ca.pem"}]
          |> read_runtime()
          |> repo(unquote(mod))
          |> Keyword.fetch!(:ssl_opts)

        assert ssl_opts[:cacertfile] == "/etc/ssl/db-ca.pem"
        refute ssl_opts[:cacerts]
      end
    end
  end

  test "the host name checked is the one in each URL" do
    config = read_runtime()

    assert repo(config, CashLens.Repo)[:ssl_opts][:server_name_indication] ==
             ~c"db.example.org"

    assert repo(config, CashLens.MigrationRepo)[:ssl_opts][:server_name_indication] ==
             ~c"db-owner.example.org"
  end

  test "the two repos connect with their own URLs" do
    config = read_runtime()
    assert repo(config, CashLens.Repo)[:url] =~ "cash_lens_app"
    assert repo(config, CashLens.MigrationRepo)[:url] =~ "owner"
    assert repo(config, CashLens.MigrationRepo)[:priv] == "priv/repo"
  end

  test "there is no environment switch that turns TLS off" do
    source = File.read!("config/runtime.exs")
    refute source =~ ~r/ssl:\s*(false|System)/
    refute source =~ "verify_none"
  end

  test "raises when DATABASE_URL is unset" do
    assert_raise RuntimeError, ~r/DATABASE_URL is missing/, fn ->
      read_runtime([{"DATABASE_URL", nil}])
    end
  end

  test "raises when MIGRATION_DATABASE_URL is unset" do
    assert_raise RuntimeError, ~r/MIGRATION_DATABASE_URL is missing/, fn ->
      read_runtime([{"MIGRATION_DATABASE_URL", nil}])
    end
  end
end
