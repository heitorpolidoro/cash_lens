defmodule CashLens.UserOwnershipMigrationTest do
  # Not async: the test rolls the migration back and re-applies it inside the
  # sandbox transaction, which takes table locks other tests must not contend
  # for. Postgres DDL is transactional, so the sandbox rollback restores the
  # real schema afterwards.
  use CashLens.DataCase, async: false

  import CashLens.UsersFixtures

  alias Ecto.Migrator

  @version 20_261_013_130_000
  @path Path.expand(
          "../../priv/repo/migrations/20261013130000_add_user_id_to_domain_tables.exs",
          __DIR__
        )

  setup_all do
    {:ok, mig: Code.compile_file(@path) |> hd() |> elem(0)}
  end

  setup %{mig: mig} do
    on_exit(fn -> System.delete_env("CASH_LENS_OPERATOR_EMAIL") end)
    Migrator.down(Repo, @version, mig, log: false, migration_lock: false)
    :ok
  end

  defp insert_rows do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("categories", [
      %{id: Ecto.UUID.bingenerate(), name: "c1", inserted_at: now, updated_at: now}
    ])

    Repo.insert_all("accounts", [
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

  defp owners(table), do: Repo.query!("SELECT user_id::text FROM #{table}").rows |> List.flatten()

  defp column_exists?(table) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = 'user_id'",
        [table]
      )

    n == 1
  end

  test "a single user takes over every existing row", %{mig: mig} do
    user = user_fixture()
    insert_rows()

    Migrator.up(Repo, @version, mig, log: false, migration_lock: false)

    assert owners("categories") == [user.id]
    assert owners("accounts") == [user.id]
  end

  test "several users and no env var raise and change nothing", %{mig: mig} do
    user_fixture()
    user_fixture()
    insert_rows()

    assert_raise RuntimeError, ~r/CASH_LENS_OPERATOR_EMAIL/, fn ->
      Migrator.up(Repo, @version, mig, log: false, migration_lock: false)
    end

    refute column_exists?("accounts")
    refute column_exists?("categories")
  end

  test "the env var picks the owner among several users", %{mig: mig} do
    user_fixture()
    chosen = user_fixture()
    insert_rows()
    System.put_env("CASH_LENS_OPERATOR_EMAIL", String.upcase(to_string(chosen.email)))

    Migrator.up(Repo, @version, mig, log: false, migration_lock: false)

    assert owners("accounts") == [chosen.id]
    assert owners("categories") == [chosen.id]
  end

  test "an env var naming nobody raises", %{mig: mig} do
    user_fixture()
    insert_rows()
    System.put_env("CASH_LENS_OPERATOR_EMAIL", "nobody@example.com")

    assert_raise RuntimeError, ~r/does not match any user/, fn ->
      Migrator.up(Repo, @version, mig, log: false, migration_lock: false)
    end
  end

  test "empty tables need no operator, even with zero users", %{mig: mig} do
    Migrator.up(Repo, @version, mig, log: false, migration_lock: false)
    assert column_exists?("accounts")
  end

  test "data and zero users raise", %{mig: mig} do
    insert_rows()

    assert_raise RuntimeError, ~r/CASH_LENS_OPERATOR_EMAIL/, fn ->
      Migrator.up(Repo, @version, mig, log: false, migration_lock: false)
    end
  end
end
