defmodule Mix.Tasks.CashLens.Db.ProvisionTest do
  # Grants touch the catalog of the shared test database: keep it alone.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.CashLens.Db.Provision
  alias Mix.Tasks.CashLens.Db.VerifyRole

  @roles_sql File.read!("priv/repo/roles.sql")

  describe "statements/2" do
    test "drops comments and splits on end-of-line semicolons" do
      script = """
      -- a comment; with a semicolon
      SELECT 1;

      REVOKE CREATE ON SCHEMA public FROM PUBLIC;
      """

      assert Provision.statements(script, "pw") ==
               ["SELECT 1;", "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"]
    end

    test "keeps a DO block, with its inner semicolons, as one statement" do
      script = """
      DO $$
      BEGIN
        PERFORM 1;
        PERFORM 2;
      END $$;

      SELECT 2;
      """

      assert [do_block, "SELECT 2;"] = Provision.statements(script, "pw")
      assert do_block =~ "PERFORM 1;"
      assert do_block =~ "PERFORM 2;"
      assert String.starts_with?(do_block, "DO $$")
    end

    test "substitutes the password as a quoted literal, escaping quotes" do
      script = "SELECT set_config('x', :'app_password', false);"

      assert Provision.statements(script, "it's") ==
               ["SELECT set_config('x', 'it''s', false);"]
    end

    test "the real script has no leftover psql variable and is non-empty" do
      statements = Provision.statements(@roles_sql, "pw")

      assert length(statements) > 8
      refute Enum.any?(statements, &(&1 =~ ":'app_password'"))
      assert Enum.any?(statements, &(&1 =~ "NOBYPASSRLS"))
      assert Enum.any?(statements, &(&1 =~ "ALTER DEFAULT PRIVILEGES"))
    end
  end

  test "running the task twice is harmless and leaves a role that passes the checks" do
    # Provisioning runs inside this sandbox transaction and is rolled back; the
    # role it re-applies already exists with the same attributes.
    Sandbox.checkout(CashLens.MigrationRepo)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    assert Provision.run([]) == :ok
    assert Provision.run([]) == :ok

    results =
      CashLens.Repo.config()
      |> VerifyRole.connection_config()
      |> VerifyRole.verify()

    assert Enum.all?(results, &match?({_, :ok}, &1)), inspect(results)
  end
end
