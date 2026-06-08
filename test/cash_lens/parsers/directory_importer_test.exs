defmodule CashLens.Parsers.DirectoryImporterTest do
  use CashLens.DataCase, async: false
  import CashLens.AccountsFixtures

  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Parsers.DirectoryImporter.Result

  @bb_sample File.read!("test/support/fixtures/files/bb_sample.csv")

  setup do
    root = Path.join(System.tmp_dir!(), "dirimp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp account_folder(root, name, bank, account_name, files) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".account"), "bank: #{bank}\naccount: #{account_name}\n")
    Enum.each(files, fn {fname, content} -> File.write!(Path.join(dir, fname), content) end)
    dir
  end

  describe "run/2 on a single account folder" do
    test "imports matching files into the resolved account", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato.csv", @bb_sample}
        ])

      assert %Result{accounts: [entry], warnings: [], errors: []} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert entry.bank == "Banco do Brasil"
      assert entry.name == "Conta Corrente"
      assert entry.imported == 3
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end

    test "warns and skips files whose extension does not match the parser", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato.csv", @bb_sample},
          {"fatura.ofx", "<OFX></OFX>"}
        ])

      assert %Result{accounts: [entry], warnings: [warning]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert entry.imported == 3
      assert warning =~ "fatura.ofx"
    end

    test "errors (without raising) when account is not found", %{root: root} do
      dir = account_folder(root, "x", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

      assert %Result{accounts: [], errors: [error]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert error =~ "não encontrada"
    end

    test "errors when account is ambiguous", %{root: root} do
      account_fixture(bank: "Banco Dup", name: "Conta Corrente", parser_type: "bb_csv")
      account_fixture(bank: "Banco Dup", name: "Conta Corrente", parser_type: "bb_csv")
      dir = account_folder(root, "d", "Banco Dup", "Conta Corrente", [{"e.csv", @bb_sample}])

      assert %Result{errors: [error]} = DirectoryImporter.run(dir, skip_installments: true)
      assert error =~ "ambígua"
    end

    test "re-running imports zero new rows (idempotent via dedupe)", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

      DirectoryImporter.run(dir, skip_installments: true)
      assert %Result{accounts: [entry]} = DirectoryImporter.run(dir, skip_installments: true)

      assert entry.imported == 0
      assert entry.skipped == 3
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 3
    end
  end

  describe "run/2 on a parent folder" do
    test "imports each subfolder that has an .account", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_fixture(bank: "Bradesco", name: "Conta Corrente", parser_type: "bb_csv")

      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
      account_folder(root, "brad", "Bradesco", "Conta Corrente", [{"e.csv", @bb_sample}])

      assert %Result{accounts: accounts, warnings: [], errors: []} =
               DirectoryImporter.run(root, skip_installments: true)

      assert length(accounts) == 2
      assert length(CashLens.Repo.all(CashLens.Transactions.Transaction)) == 6
    end

    test "warns and skips subfolders without an .account", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

      no_acct = Path.join(root, "fatura-antiga")
      File.mkdir_p!(no_acct)
      File.write!(Path.join(no_acct, "x.csv"), @bb_sample)

      assert %Result{accounts: [_], warnings: [warning]} =
               DirectoryImporter.run(root, skip_installments: true)

      assert warning =~ "fatura-antiga"
      assert warning =~ "sem .account"
    end

    test "one bad subfolder does not abort the others", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_folder(root, "ok", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
      account_folder(root, "bad", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

      assert %Result{accounts: [_], errors: [error]} =
               DirectoryImporter.run(root, skip_installments: true)

      assert error =~ "não encontrada"
    end
  end
end
