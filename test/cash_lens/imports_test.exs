defmodule CashLens.ImportsTest do
  use CashLens.DataCase, async: false

  import CashLens.AccountsFixtures

  alias CashLens.Imports
  alias CashLens.Imports.ImportedFile
  alias CashLens.Imports.ImportRun
  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Parsers.Ingestor

  @bb_sample File.read!("test/support/fixtures/files/bb_sample.csv")

  @other_sample """
  Data,Dependência Origem,Term. Origem,Histórico,Documento,Valor,
  20/02/2026,0000,0000,SALDO ANTERIOR,,0.00,
  24/02/2026,1234,5678,OUTRA COISA,123.456,-99.00,
  """

  setup do
    root = Path.join(System.tmp_dir!(), "imports_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    account =
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    {:ok, root: root, account: account}
  end

  defp account_folder(root, name, opts \\ []) do
    bank = Keyword.get(opts, :bank, "Banco do Brasil")
    account_name = Keyword.get(opts, :account, "Conta Corrente")
    parser = Keyword.get(opts, :parser, "bb_csv")

    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".account"),
      "bank: #{bank}\naccount: #{account_name}\nparser: #{parser}\n"
    )

    dir
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp entry_for(entries, relative_path) do
    Enum.find(entries, &(&1.path == relative_path))
  end

  describe "scan/1 on an invalid root" do
    test "returns an error tuple instead of raising" do
      assert {:error, :not_a_directory} = Imports.scan("/no/such/dir/#{System.unique_integer()}")
      assert {:error, :not_a_directory} = Imports.scan(nil)
    end
  end

  describe "scan/1 status classification" do
    test "reports a never-imported file as :new", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, [entry]} = Imports.scan(root)
      assert entry.path == "bb/extrato.csv"
      assert entry.status == :new
      assert entry.bank == "Banco do Brasil"
      assert entry.account == "Conta Corrente"
      assert entry.account_dir == "bb"
      assert entry.absolute_path == Path.expand(Path.join(dir, "extrato.csv"))
      assert String.length(entry.content_hash) == 64
      assert %DateTime{} = entry.mtime
      assert entry.last_imported_at == nil
    end

    test "reports an imported, untouched file as :synced", %{root: root, account: account} do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, _summary} = Ingestor.import_file(account, path, import_root: root)

      assert {:ok, [entry]} = Imports.scan(root)
      assert entry.status == :synced
      assert %DateTime{} = entry.last_imported_at
    end

    test "reports :updated when only the content changed", %{root: root, account: account} do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)
      assert {:ok, _} = Ingestor.import_file(account, path, import_root: root)

      %{mtime: mtime} = File.stat!(path, time: :posix)
      File.write!(path, @other_sample)
      File.touch!(path, mtime)

      assert {:ok, [entry]} = Imports.scan(root)
      assert entry.status == :updated
    end

    test "reports :updated when only the mtime changed", %{root: root, account: account} do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)
      assert {:ok, _} = Ingestor.import_file(account, path, import_root: root)

      recorded = Imports.get_imported_file_by_path("bb/extrato.csv")
      File.touch!(path, System.os_time(:second) + 3600)

      assert {:ok, [entry]} = Imports.scan(root)
      assert entry.status == :updated
      assert entry.content_hash == recorded.content_hash
    end

    test "recognises a row recorded under its absolute path", %{root: root, account: account} do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      # No :import_root and no configured setting root → the row is keyed absolutely.
      assert {:ok, _} = Ingestor.import_file(account, path, import_root: nil)
      assert Imports.get_imported_file_by_path(Path.expand(path))

      assert {:ok, [entry]} = Imports.scan(root)
      assert entry.path == "bb/extrato.csv"
      assert entry.status == :synced
    end
  end

  describe "scan/1 omissions" do
    test "omits files in a folder with no .account marker", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      loose = Path.join(root, "solto")
      File.mkdir_p!(loose)
      write_file(loose, "avulso.csv", @bb_sample)

      assert {:ok, entries} = Imports.scan(root)
      assert Enum.map(entries, & &1.path) == ["bb/extrato.csv"]
    end

    test "omits a dangling symlink without raising", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)
      File.ln_s!(Path.join(dir, "nao_existe.csv"), Path.join(dir, "quebrado.csv"))

      assert {:ok, entries} = Imports.scan(root)
      assert Enum.map(entries, & &1.path) == ["bb/extrato.csv"]
    end

    test "omits an unreadable file without raising", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)
      secret = write_file(dir, "secreto.csv", @bb_sample)
      File.chmod!(secret, 0o000)
      on_exit(fn -> File.chmod(secret, 0o644) end)

      assert {:ok, entries} = Imports.scan(root)
      assert Enum.map(entries, & &1.path) == ["bb/extrato.csv"]
    end

    test "omits a recorded path that no longer exists, keeping its row", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      {:ok, _row} =
        Imports.upsert_imported_file(%{
          path: "bb/sumiu.csv",
          content_hash: "deadbeef",
          mtime: DateTime.utc_now() |> DateTime.truncate(:second),
          last_imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, entries} = Imports.scan(root)
      assert Enum.map(entries, & &1.path) == ["bb/extrato.csv"]
      assert Imports.get_imported_file_by_path("bb/sumiu.csv")
    end

    test "omits files whose extension does not match the account's parser_type", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)
      write_file(dir, "fatura.ofx", "<OFX></OFX>")

      assert {:ok, entries} = Imports.scan(root)
      assert Enum.map(entries, & &1.path) == ["bb/extrato.csv"]
    end
  end

  describe "relative_path/2" do
    test "returns a root-relative key for a file under the root", %{root: root} do
      assert Imports.relative_path(Path.join([root, "bb", "e.csv"]), root) == "bb/e.csv"
    end

    test "returns the absolute path for a file outside the root", %{root: root} do
      other = Path.join(System.tmp_dir!(), "fora_#{System.unique_integer([:positive])}.csv")
      assert Imports.relative_path(other, root) == Path.expand(other)
    end

    test "returns the absolute path when the root is nil or blank", %{root: root} do
      file = Path.join([root, "bb", "e.csv"])
      assert Imports.relative_path(file, nil) == Path.expand(file)
      assert Imports.relative_path(file, "") == Path.expand(file)
      assert Imports.relative_path(file, "   ") == Path.expand(file)
    end
  end

  describe "import_root/1" do
    test "prefers a non-blank :import_root option" do
      assert Imports.import_root(import_root: "/tmp/monitorado") == "/tmp/monitorado"
    end

    test "never turns a blank root into the current working directory" do
      refute Imports.import_root(import_root: "") == Path.expand("")
      refute Imports.import_root(import_root: "  ") == Path.expand("")
    end
  end

  describe "recording a real import" do
    test "writes one imported_files row and exactly one matching import_run", %{
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, summary} = Ingestor.import_file(account, path, import_root: root)

      assert [file_row] = Repo.all(ImportedFile)
      assert file_row.path == "bb/extrato.csv"
      assert file_row.content_hash == Imports.content_hash(@bb_sample)
      assert file_row.mtime == Imports.file_mtime(path)
      assert %DateTime{} = file_row.last_imported_at

      assert [run] = Repo.all(ImportRun)
      assert run.status == "success"
      assert run.file_path == "bb/extrato.csv"
      assert run.account_id == account.id
      assert run.imported_file_id == file_row.id
      assert run.imported_count == summary.imported
      assert run.skipped_count == summary.skipped
      assert run.failed_count == 0
      assert run.error_message == nil
    end

    test "re-importing an unchanged file adds a run but no second file row", %{
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, first} = Ingestor.import_file(account, path, import_root: root)
      assert first.imported == 3

      assert {:ok, second} = Ingestor.import_file(account, path, import_root: root)
      assert second.imported == 0

      assert [_only_one] = Repo.all(ImportedFile)

      runs = Repo.all(from(r in ImportRun, order_by: [asc: r.inserted_at]))
      assert length(runs) == 2
      assert Enum.any?(runs, &(&1.imported_count == 0 and &1.skipped_count == 3))
    end

    test "records an error run for an unreadable file", %{root: root, account: account} do
      missing = Path.join(root, "nao_existe.csv")

      assert {:error, reason} = Ingestor.import_file(account, missing, import_root: root)
      assert reason =~ "Could not read file"

      assert [] = Repo.all(ImportedFile)
      assert [run] = Repo.all(ImportRun)
      assert run.status == "error"
      assert run.imported_count == 0
      assert run.skipped_count == 0
      assert run.error_message =~ "Could not read file"
    end

    test "records an error run when the parser rejects the file", %{root: root} do
      account =
        account_fixture(bank: "Banco X", name: "Sem Parser", parser_type: "parser_inexistente")

      dir = account_folder(root, "x", bank: "Banco X", account: "Sem Parser")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:error, _reason} = Ingestor.import_file(account, path, import_root: root)

      assert [] = Repo.all(ImportedFile)
      assert [run] = Repo.all(ImportRun)
      assert run.status == "error"
      assert run.imported_count == 0
      assert run.skipped_count == 0
      assert is_binary(run.error_message)
    end

    test "restricts status to the closed success/warning/error vocabulary", %{account: account} do
      assert ImportRun.statuses() == ["success", "warning", "error"]

      base = %{
        ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
        account_id: account.id,
        file_path: "bb/extrato.csv"
      }

      for status <- ImportRun.statuses() do
        assert {:ok, _run} = Imports.record_run(Map.put(base, :status, status))
      end

      assert {:error, changeset} = Imports.record_run(Map.put(base, :status, "partial"))
      assert "is invalid" in errors_on(changeset).status
    end
  end

  describe "dry runs write nothing" do
    test "a dry-run import leaves both tables empty", %{root: root, account: account} do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, summary} =
               Ingestor.import_file(account, path, dry_run: true, import_root: root)

      assert summary.imported == 3

      assert Repo.all(ImportedFile) == []
      assert Repo.all(ImportRun) == []
    end

    test "a dry run over an unreadable file writes nothing", %{root: root, account: account} do
      missing = Path.join(root, "nao_existe.csv")

      assert {:error, _} =
               Ingestor.import_file(account, missing, dry_run: true, import_root: root)

      assert Repo.all(ImportedFile) == []
      assert Repo.all(ImportRun) == []
    end

    test "a dry run over a file the parser rejects writes nothing", %{root: root} do
      account =
        account_fixture(bank: "Banco Y", name: "Sem Parser", parser_type: "parser_inexistente")

      dir = account_folder(root, "y", bank: "Banco Y", account: "Sem Parser")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:error, _} = Ingestor.import_file(account, path, dry_run: true, import_root: root)

      assert Repo.all(ImportedFile) == []
      assert Repo.all(ImportRun) == []
    end

    test "a DirectoryImporter dry run writes nothing", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      DirectoryImporter.run(root, dry_run: true, skip_installments: true)

      assert Repo.all(ImportedFile) == []
      assert Repo.all(ImportRun) == []
    end
  end

  describe "DirectoryImporter.run/2 plumbing" do
    test "stores a root-relative path so a following scan reports :synced", %{root: root} do
      dir = account_folder(root, "bb")
      write_file(dir, "extrato.csv", @bb_sample)

      DirectoryImporter.run(root, skip_installments: true)

      assert [file_row] = Repo.all(ImportedFile)
      refute String.starts_with?(file_row.path, "/")
      assert file_row.path == "bb/extrato.csv"

      assert {:ok, entries} = Imports.scan(root)
      assert entry_for(entries, "bb/extrato.csv").status == :synced
    end
  end

  describe "list_recent_runs/1" do
    test "returns the newest runs first with the account preloaded", %{
      root: root,
      account: account
    } do
      dir = account_folder(root, "bb")
      path = write_file(dir, "extrato.csv", @bb_sample)

      assert {:ok, _} = Ingestor.import_file(account, path, import_root: root)
      assert {:ok, _} = Ingestor.import_file(account, path, import_root: root)

      runs = Imports.list_recent_runs(1)
      assert length(runs) == 1
      assert hd(runs).account.id == account.id
    end
  end

  describe "account_for_entry/1" do
    test "resolves the single account matching the entry's bank and name", %{account: account} do
      entry = %{bank: "Banco do Brasil", account: "Conta Corrente"}

      assert {:ok, resolved} = Imports.account_for_entry(entry)
      assert resolved.id == account.id
    end

    test "returns :not_found when no account matches" do
      entry = %{bank: "Banco Inexistente", account: "Conta Fantasma"}

      assert {:error, :not_found} = Imports.account_for_entry(entry)
    end

    test "returns :ambiguous when more than one account matches" do
      account_fixture(bank: "Itau", name: "Conta Dupla", parser_type: "bb_csv")
      account_fixture(bank: "Itau", name: "Conta Dupla", parser_type: "bb_csv")

      entry = %{bank: "Itau", account: "Conta Dupla"}

      assert {:error, :ambiguous} = Imports.account_for_entry(entry)
    end
  end
end
