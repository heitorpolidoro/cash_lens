defmodule Mix.Tasks.CashLens.Db.VerifyRoleTest do
  # Plain ExUnit (no sandbox): the task opens its own connections and its
  # rolled-back DDL probes take table locks the sandbox must not contend with.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.CashLens.Db.VerifyRole

  defp app_config, do: VerifyRole.connection_config(CashLens.Repo.config())
  defp owner_config, do: VerifyRole.connection_config(CashLens.MigrationRepo.config())

  test "the runtime role passes every check" do
    results = VerifyRole.verify(app_config())

    assert Enum.map(results, &elem(&1, 0)) == [
             "role attributes",
             "CREATE TABLE is refused",
             "DROP TABLE is refused",
             "ALTER ROLE is refused",
             "another database is refused"
           ]

    assert Enum.all?(results, &match?({_, :ok}, &1)), inspect(results)
  end

  test "the app role really is the one the Repo connects as" do
    Sandbox.checkout(CashLens.Repo)
    assert app_config()[:username] == "cash_lens_app"
    refute owner_config()[:username] == "cash_lens_app"

    assert %{rows: [["cash_lens_app", false, false, false, false]]} =
             CashLens.Repo.query!(
               "SELECT current_user, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls " <>
                 "FROM pg_roles WHERE rolname = current_user"
             )
  end

  test "an over-privileged role fails every check, and nothing is changed" do
    Sandbox.checkout(CashLens.MigrationRepo)
    results = VerifyRole.verify(owner_config())

    failed = for {check, {:error, _}} <- results, do: check

    assert "role attributes" in failed
    assert "CREATE TABLE is refused" in failed
    assert "DROP TABLE is refused" in failed
    assert "ALTER ROLE is refused" in failed
    assert "another database is refused" in failed

    # The probes were rolled back.
    assert %{rows: [[0]]} =
             CashLens.MigrationRepo.query!(
               "SELECT count(*) FROM pg_tables WHERE tablename = 'cl_verify_role_probe'"
             )
  end

  test "a role that cannot log in is reported, not raised" do
    results = VerifyRole.verify(Keyword.put(app_config(), :password, "wrong"))
    assert [{"connect as the runtime role", {:error, message}}] = results
    assert message =~ "cannot connect"
  end

  describe "run/1" do
    test "returns :ok for the runtime role" do
      output = capture_io(fn -> assert VerifyRole.run([]) == :ok end)
      assert output =~ "ok    CREATE TABLE is refused"
    end

    test "exits non-zero when the Repo is configured with a privileged role" do
      original = Application.get_env(:cash_lens, CashLens.Repo)
      owner = Application.get_env(:cash_lens, CashLens.MigrationRepo)
      on_exit(fn -> Application.put_env(:cash_lens, CashLens.Repo, original) end)

      Application.put_env(
        :cash_lens,
        CashLens.Repo,
        Keyword.merge(original, Keyword.take(owner, [:username, :password]))
      )

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert catch_exit(VerifyRole.run([])) == {:shutdown, 1} end)
        end)

      assert stderr =~ "FAIL  CREATE TABLE is refused"
    end
  end
end
