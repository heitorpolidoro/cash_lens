defmodule CashLens.UserScopingAuditTest do
  @moduledoc """
  Guard check for tenant isolation: every function under `lib/` that queries
  the database must either filter through `Ownership.scope/2` or name a
  `user_id`. A new unscoped query fails here instead of leaking one user's rows
  to another.

  The scan is textual and deliberately coarse: `lib/` is split into blocks at
  each `def`/`defp`, and a block is an offender when it runs a query (`Repo.all`,
  `Repo.get_by`, `from(x in ...)`, ...) without either marker. Do not extend
  `@allow_list`: fix the offender in code.
  """
  use ExUnit.Case, async: true

  # Files that legitimately query without a per-user filter.
  @allow_list [
    # Users are the tenants themselves; accounts are looked up by email/token/id.
    "lib/cash_lens/users.ex",
    # The login audit log is keyed by email and may refer to unknown users.
    "lib/cash_lens/audit.ex",
    # The health check pings the database and reads no user data.
    "lib/cash_lens/health.ex",
    # Account export/deletion walks the owned-data registry for one given user id.
    "lib/cash_lens/privacy.ex",
    # Defines `scope/2` itself and the owner lookup behind `validate_owned/3`.
    "lib/cash_lens/ownership.ex",
    # The supervision tree runs startup checks outside any user context.
    "lib/cash_lens/application.ex"
  ]

  @query ~r/Repo\.(all|one|get|get!|get_by|get_by!|update_all|delete_all|aggregate|exists\?|stream|insert_all)\(|\bfrom\(?\s*\w+\s+in\s+/
  @markers ["Ownership.scope(", "user_id"]

  @doc false
  # Splits `source` into blocks that each start at a `def`/`defp` line.
  def blocks(source) do
    source
    |> String.split(~r/^\s*defp?\s/m, trim: false)
    |> Enum.drop(1)
  end

  @doc false
  def offenders(source) do
    source
    |> blocks()
    |> Enum.filter(fn block ->
      Regex.match?(@query, block) and not Enum.any?(@markers, &String.contains?(block, &1))
    end)
  end

  defp lib_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&(&1 in @allow_list))
  end

  test "the allow-list holds only the six documented files" do
    assert length(@allow_list) == 6
    assert Enum.all?(@allow_list, &File.regular?/1)
  end

  test "every query under lib/ is scoped by the user" do
    found =
      for file <- lib_files(),
          block <- offenders(File.read!(file)) do
        {file, block |> String.split("\n") |> hd() |> String.trim()}
      end

    assert found == [], "unscoped queries:\n" <> Enum.map_join(found, "\n", &inspect/1)
  end

  describe "the scanner" do
    test "flags an unscoped query" do
      source = """
      defmodule Leaky do
        def everything, do: Repo.all(Thing)
      end
      """

      assert [_] = offenders(source)
    end

    test "flags an unscoped from/in query" do
      source = """
      defmodule Leaky do
        def names do
          from(t in Thing, select: t.name)
        end
      end
      """

      assert [_] = offenders(source)
    end

    test "accepts a query filtered through Ownership.scope/2" do
      source = """
      defmodule Fine do
        def mine(user), do: Thing |> Ownership.scope(user) |> Repo.all()
      end
      """

      assert offenders(source) == []
    end

    test "accepts a query naming user_id" do
      source = """
      defmodule Fine do
        def mine(user_id), do: Repo.get_by(Thing, user_id: user_id)
      end
      """

      assert offenders(source) == []
    end

    test "judges each function on its own" do
      source = """
      defmodule Mixed do
        def scoped(user), do: Thing |> Ownership.scope(user) |> Repo.all()
        defp leaky, do: Repo.one(Thing)
      end
      """

      assert [block] = offenders(source)
      assert block =~ "leaky"
    end
  end
end
