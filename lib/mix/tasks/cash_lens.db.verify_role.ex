defmodule Mix.Tasks.CashLens.Db.VerifyRole do
  @shortdoc "Fails unless the runtime database role is least-privilege"
  @moduledoc """
  Connects as the runtime role (the one `CashLens.Repo` is configured with) and
  checks that it is actually unprivileged. Exits 0 only when all of these hold:

    * the role is not superuser, and has no createdb, createrole or bypassrls;
    * `CREATE TABLE` is refused;
    * `DROP TABLE` is refused;
    * `ALTER ROLE` is refused;
    * connecting to another database is refused.

  Every DDL probe runs inside a transaction that is rolled back, so a role that
  is wrongly privileged is reported without anything being changed.

      mix cash_lens.db.verify_role

  Run it after provisioning (`mix cash_lens.db.provision` or
  `priv/repo/roles.sql`) and in CI/deploy; see docs/security.md.
  """
  use Mix.Task

  require Logger

  @connection_keys [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :ssl,
    :ssl_opts,
    :socket_options,
    :socket
  ]

  # A database the app role has no business in. `postgres` exists on every
  # cluster; `template1` is the fallback when the app database is `postgres`.
  @other_databases ["postgres", "template1"]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ssl)

    config = connection_config(CashLens.Repo.config())
    results = verify(config)

    for {check, result} <- results do
      case result do
        :ok -> Mix.shell().info("ok    #{check}")
        {:error, message} -> Mix.shell().error("FAIL  #{check}: #{message}")
      end
    end

    if Enum.any?(results, &match?({_, {:error, _}}, &1)) do
      Mix.shell().error("The runtime role is not least-privilege (see docs/security.md).")
      exit({:shutdown, 1})
    end

    :ok
  end

  @doc "Reduces a repo config to what Postgrex needs to connect."
  def connection_config(repo_config), do: Keyword.take(repo_config, @connection_keys)

  @doc """
  Runs every check with the given Postgrex connection options and returns
  `[{check_name, :ok | {:error, message}}]`.
  """
  def verify(config) do
    case open(config) do
      {:ok, conn} ->
        try do
          [
            {"role attributes", role_attributes(conn)},
            {"CREATE TABLE is refused",
             refused(conn, "CREATE TABLE cl_verify_role_probe (id int)")},
            {"DROP TABLE is refused", refused(conn, drop_probe(conn))},
            {"ALTER ROLE is refused", refused(conn, "ALTER ROLE CURRENT_USER CREATEDB")},
            {"another database is refused", other_database_refused(conn, config)}
          ]
        after
          GenServer.stop(conn)
        end

      {:error, message} ->
        [{"connect as the runtime role", {:error, message}}]
    end
  end

  defp open(config) do
    case start_and_ping(config) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, "cannot connect: #{format(error)}"}
    end
  end

  # `backoff_type: :stop` makes a refused login end the connection instead of
  # being retried in the background; the failed first query reports it.
  defp start_and_ping(config) do
    trapping? = Process.flag(:trap_exit, true)
    # A refused login is the expected outcome here, not an error to log.
    level = Logger.level()
    Logger.configure(level: :none)

    try do
      {:ok, conn} = Postgrex.start_link(Keyword.merge(config, backoff_type: :stop, pool_size: 1))

      case Postgrex.query(conn, "SELECT 1", [], timeout: 5_000) do
        {:ok, _} ->
          {:ok, conn}

        {:error, error} ->
          if Process.alive?(conn), do: GenServer.stop(conn)
          {:error, error}
      end
    catch
      :exit, reason -> {:error, reason}
    after
      flush_exits()
      Logger.configure(level: level)
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      50 -> :ok
    end
  end

  defp role_attributes(conn) do
    sql = """
    SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls
    FROM pg_roles WHERE rolname = current_user
    """

    %{rows: [[name | flags]]} = Postgrex.query!(conn, sql, [])

    offending =
      [:superuser, :createdb, :createrole, :bypassrls]
      |> Enum.zip(flags)
      |> Enum.filter(fn {_attribute, set?} -> set? end)
      |> Enum.map(&elem(&1, 0))

    case offending do
      [] -> :ok
      attributes -> {:error, "#{name} has #{Enum.join(attributes, ", ")}"}
    end
  end

  # Names an existing table so the DROP is realistic; it is rolled back anyway.
  defp drop_probe(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1 LIMIT 1",
        []
      )

    case rows do
      [[table]] -> "DROP TABLE public.#{table}"
      [] -> "DROP TABLE public.cl_verify_role_probe"
    end
  end

  # The statement must fail with `insufficient_privilege`; any other failure
  # (say, a missing table) proves nothing about the role.
  defp refused(conn, sql) do
    result =
      Postgrex.transaction(conn, fn tx ->
        case Postgrex.query(tx, sql, []) do
          {:ok, _} -> DBConnection.rollback(tx, :succeeded)
          {:error, error} -> DBConnection.rollback(tx, {:refused, error})
        end
      end)

    case result do
      {:error, {:refused, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}} ->
        :ok

      {:error, {:refused, error}} ->
        {:error, "failed, but not for lack of privilege: #{format(error)}"}

      {:error, :succeeded} ->
        {:error, "`#{sql}` succeeded (rolled back)"}
    end
  end

  # Two independent facts: the catalog says the role lacks CONNECT on the other
  # database, and an actual login there fails.
  defp other_database_refused(conn, config) do
    current = to_string(config[:database])

    case Enum.find(@other_databases, &(&1 != current)) do
      nil ->
        :ok

      other ->
        %{rows: [[allowed?]]} =
          Postgrex.query!(conn, "SELECT has_database_privilege(current_user, $1, 'CONNECT')", [
            other
          ])

        case {allowed?, start_and_ping(Keyword.put(config, :database, other))} do
          {false, {:error, _}} ->
            :ok

          {false, {:ok, other_conn}} ->
            GenServer.stop(other_conn)
            {:error, "connected to database #{other} although CONNECT is not granted"}

          {true, {:ok, other_conn}} ->
            GenServer.stop(other_conn)
            {:error, "connected to database #{other}"}

          {true, {:error, _}} ->
            {:error, "has CONNECT on database #{other}"}
        end
    end
  end

  defp format(%{__exception__: true} = error), do: Exception.message(error)
  defp format(other), do: inspect(other)
end
