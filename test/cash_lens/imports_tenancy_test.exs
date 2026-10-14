defmodule CashLens.ImportsTenancyTest do
  @moduledoc """
  User B never reads user A's import runs, imported files or accounts, and the
  rows a user writes through `Imports` are owned by that user.

  Calls made for B run with the process pinned to A on purpose: row-level
  security would then let A's rows through, so what keeps them out of B's
  results is only the application-level `Ownership.scope/2` filter.
  """
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Imports
  alias CashLens.Imports.ImportedFile
  alias CashLens.Imports.ImportRun
  alias CashLens.Tenancy

  @ran_at ~U[2026-03-01 10:00:00Z]

  setup do
    %{a: a, b: b} = cross_tenant()

    root = Path.join(System.tmp_dir!(), "imports_tenancy_#{System.unique_integer([:positive])}")
    dir = Path.join(root, "bb")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".account"), "bank: Banco A\naccount: Conta A\nparser: bb_csv\n")
    File.write!(Path.join(dir, "a.csv"), "Data,x\n")
    on_exit(fn -> File.rm_rf!(root) end)

    seeded =
      Tenancy.acting_as(a, fn ->
        account =
          account_fixture(%{user: a, bank: "Banco A", name: "Conta A", parser_type: "bb_csv"})

        {:ok, file} =
          Imports.upsert_imported_file(a, %{
            path: "bb/a.csv",
            content_hash: Imports.content_hash("Data,x\n"),
            mtime: @ran_at,
            last_imported_at: @ran_at
          })

        {:ok, run} =
          Imports.record_run(a, %{
            ran_at: @ran_at,
            account_id: account.id,
            imported_file_id: file.id,
            file_path: "bb/a.csv",
            status: "success",
            imported_count: 3
          })

        %{account: account, imported: file, run: run}
      end)

    {:ok, Map.merge(%{a: a, b: b, root: root}, seeded)}
  end

  # B's calls run while the process is pinned to A.
  defp as_b(a, fun), do: Tenancy.acting_as(a, fun)

  describe "reads" do
    test "A sees their own runs and files", %{a: a, run: run, imported: file} do
      Tenancy.acting_as(a, fn ->
        assert [%{id: run_id}] = Imports.list_recent_runs(a)
        assert run_id == run.id
        assert Imports.get_imported_file_by_path(a, "bb/a.csv").id == file.id
        assert %{"bb/a.csv" => %{id: id}} = Imports.map_by_paths(a, ["bb/a.csv"])
        assert id == file.id
      end)
    end

    test "B's list_recent_runs returns nothing of A's", %{a: a, b: b} do
      assert as_b(a, fn -> Imports.list_recent_runs(b) end) == []
    end

    test "B's get_imported_file_by_path returns nil for A's path", %{a: a, b: b} do
      assert as_b(a, fn -> Imports.get_imported_file_by_path(b, "bb/a.csv") end) == nil
    end

    test "B's map_by_paths returns an empty map for A's path", %{a: a, b: b} do
      assert as_b(a, fn -> Imports.map_by_paths(b, ["bb/a.csv"]) end) == %{}
    end

    test "B's scan sees A's file as new", %{a: a, b: b, root: root} do
      assert {:ok, [%{status: :new}]} = as_b(a, fn -> Imports.scan(b, root) end)
    end

    test "B cannot resolve or list A's accounts", %{a: a, b: b} do
      entry = %{bank: "Banco A", account: "Conta A"}
      assert as_b(a, fn -> Imports.account_for_entry(b, entry) end) == {:error, :not_found}

      verdict = %{format: :csv, parser_type: "bb_csv"}
      assert as_b(a, fn -> Imports.candidate_accounts(b, verdict) end) == []

      Tenancy.acting_as(a, fn ->
        assert [_] = Imports.candidate_accounts(a, verdict)
        assert {:ok, _} = Imports.account_for_entry(a, entry)
      end)
    end
  end

  describe "writes" do
    test "rows written by B are owned by B and A's are unchanged", ctx do
      %{a: a, b: b, run: run, imported: file} = ctx

      {file_b, run_b} =
        Tenancy.acting_as(b, fn ->
          {:ok, file_b} =
            Imports.upsert_imported_file(b, %{path: "bb/b.csv", last_imported_at: @ran_at})

          {:ok, run_b} =
            Imports.record_run(b, %{ran_at: @ran_at, file_path: "bb/b.csv", status: "success"})

          {file_b, run_b}
        end)

      assert file_b.user_id == b.id
      assert run_b.user_id == b.id

      Tenancy.acting_as(a, fn ->
        assert Repo.get!(ImportedFile, file.id).user_id == a.id
        assert Repo.get!(ImportRun, run.id).user_id == a.id
      end)

      assert [only_b] = Tenancy.acting_as(b, fn -> Imports.list_recent_runs(b) end)
      assert only_b.id == run_b.id
    end
  end
end
