defmodule CashLens.UserOwnershipMigrationTest do
  # Not async: the test rolls the migration back and re-applies it inside a
  # sandbox transaction, which takes table locks other tests must not contend
  # for. Postgres DDL is transactional, so the sandbox rollback restores the
  # real schema afterwards.
  #
  # DDL needs the table owner, so this test runs on `CashLens.MigrationRepo`
  # (its own sandbox), not on the unprivileged runtime `CashLens.Repo`.
  use CashLens.DataCase, async: false

  alias CashLens.MigrationRepo
  alias CashLens.Users.User
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @migrations "../../priv/repo/migrations"
  @version 20_261_013_130_000
  @rls_version 20_261_014_120_000
  @path Path.expand("#{@migrations}/20261013130000_add_user_id_to_domain_tables.exs", __DIR__)
  @rls_path Path.expand("#{@migrations}/20261014120000_enable_row_level_security.exs", __DIR__)
  @opts [log: false, migration_lock: false]

  @moduletag :no_current_user

  setup_all do
    {:ok,
     mig: Code.compile_file(@path) |> hd() |> elem(0),
     rls_mig: Code.compile_file(@rls_path) |> hd() |> elem(0)}
  end

  setup %{mig: mig, rls_mig: rls_mig} do
    pid = Sandbox.start_owner!(MigrationRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    on_exit(fn -> System.delete_env("CASH_LENS_OPERATOR_EMAIL") end)

    # The policies reference user_id, so they go first.
    Migrator.down(MigrationRepo, @rls_version, rls_mig, @opts)
    Migrator.down(MigrationRepo, @version, mig, @opts)
    :ok
  end

  # Built by hand, not through `Users.register_user/1`: its uniqueness check runs
  # on the runtime repo, which would wait on the locks this test's DDL holds.
  defp user_fixture do
    MigrationRepo.insert!(%User{
      email: CashLens.UsersFixtures.unique_user_email(),
      hashed_password: Bcrypt.hash_pwd_salt("a-long-valid-password", log_rounds: 1)
    })
  end

  defp up(mig), do: Migrator.up(MigrationRepo, @version, mig, @opts)

  defp insert_rows do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    MigrationRepo.insert_all("categories", [
      %{id: Ecto.UUID.bingenerate(), name: "c1", inserted_at: now, updated_at: now}
    ])

    MigrationRepo.insert_all("accounts", [
      %{
        id: Ecto.UUID.bingenerate(),
        name: "a1",
        bank: "b",
        balance: 1,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp owners(table),
    do: MigrationRepo.query!("SELECT user_id::text FROM #{table}").rows |> List.flatten()

  defp column_exists?(table) do
    %{rows: [[n]]} =
      MigrationRepo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = 'user_id'",
        [table]
      )

    n == 1
  end

  test "a single user takes over every existing row", %{mig: mig} do
    user = user_fixture()
    insert_rows()

    up(mig)

    assert owners("categories") == [user.id]
    assert owners("accounts") == [user.id]
  end

  test "several users and no env var raise and change nothing", %{mig: mig} do
    user_fixture()
    user_fixture()
    insert_rows()

    assert_raise RuntimeError, ~r/CASH_LENS_OPERATOR_EMAIL/, fn ->
      up(mig)
    end

    refute column_exists?("accounts")
    refute column_exists?("categories")
  end

  test "the env var picks the owner among several users", %{mig: mig} do
    user_fixture()
    chosen = user_fixture()
    insert_rows()
    System.put_env("CASH_LENS_OPERATOR_EMAIL", String.upcase(to_string(chosen.email)))

    up(mig)

    assert owners("accounts") == [chosen.id]
    assert owners("categories") == [chosen.id]
  end

  test "an env var naming nobody raises", %{mig: mig} do
    user_fixture()
    insert_rows()
    System.put_env("CASH_LENS_OPERATOR_EMAIL", "nobody@example.com")

    assert_raise RuntimeError, ~r/does not match any user/, fn ->
      up(mig)
    end
  end

  test "empty tables need no operator, even with zero users", %{mig: mig} do
    up(mig)
    assert column_exists?("accounts")
  end

  test "data and zero users raise", %{mig: mig} do
    insert_rows()

    assert_raise RuntimeError, ~r/CASH_LENS_OPERATOR_EMAIL/, fn ->
      up(mig)
    end
  end
end
