defmodule CashLens.Parsers.DirectoryImporterTest do
  use CashLens.DataCase, async: false
  import CashLens.AccountsFixtures
  import CashLens.CreditCardsFixtures

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

  describe "run/2 on an invalid path" do
    test "returns an error instead of raising when the path does not exist" do
      assert %Result{accounts: [], warnings: [], errors: [error]} =
               DirectoryImporter.run("/no/such/path/#{System.unique_integer([:positive])}",
                 skip_installments: true
               )

      assert error =~ "não existe"
    end
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

  describe "run/2 with dry_run: true" do
    test "computes accurate per-account counts with zero writes", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato.csv", @bb_sample}
        ])

      assert %Result{accounts: [entry], errors: []} =
               DirectoryImporter.run(dir, skip_installments: true, dry_run: true)

      assert entry.imported == 3
      assert entry.skipped == 0
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0

      # A real run afterward imports exactly what the preview said it would.
      assert %Result{accounts: [real_entry]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert real_entry.imported == 3
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 3
    end

    test "two overlapping files in the same account folder are not double-counted as new",
         %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      # Same 3-row fixture content written under two different filenames in one
      # account folder: every row in file 2 fingerprint-collides with file 1.
      # A dry run must recognize that, exactly like a real import would (file
      # 1's rows are already on disk by the time file 2's on_conflict: :nothing
      # insert runs).
      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato1.csv", @bb_sample},
          {"extrato2.csv", @bb_sample}
        ])

      assert %Result{accounts: [preview_entry], errors: []} =
               DirectoryImporter.run(dir, skip_installments: true, dry_run: true)

      assert preview_entry.imported == 3
      assert preview_entry.skipped == 3
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0

      # The preview's `imported` count must equal what a subsequent real run
      # actually imports — this is the exact promise the preview makes.
      assert %Result{accounts: [real_entry]} =
               DirectoryImporter.run(dir, skip_installments: true)

      assert real_entry.imported == preview_entry.imported
      assert real_entry.imported == 3
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 3
    end

    test "does not run installment detection", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      dir =
        account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [
          {"extrato.csv", @bb_sample}
        ])

      # No installment groups exist before or after a dry run — a real (cheap,
      # observable) proxy for "scan_and_apply_all/0 was not invoked", since
      # this project's other tests reach for `skip_installments: true` rather
      # than mocking that function directly (grep this file for the existing
      # pattern before assuming a different one is expected).
      assert CashLens.Installments.list_installment_groups() == []
      DirectoryImporter.run(dir, dry_run: true)
      assert CashLens.Installments.list_installment_groups() == []
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

    test "imports subfolders recursively (multi-level nesting) containing .account", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

      # Create nested folder structure: root/bb/2026/
      bb_dir = Path.join(root, "bb")
      year_dir = Path.join(bb_dir, "2026")
      File.mkdir_p!(year_dir)

      # Write .account and sample file inside root/bb/2026/
      File.write!(
        Path.join(year_dir, ".account"),
        "bank: Banco do Brasil\naccount: Conta Corrente\n"
      )

      File.write!(Path.join(year_dir, "e.csv"), @bb_sample)

      assert %Result{accounts: [entry], warnings: [], errors: []} =
               DirectoryImporter.run(root, skip_installments: true)

      assert entry.bank == "Banco do Brasil"
      assert entry.name == "Conta Corrente"
      assert entry.imported == 3
      assert entry.folder_path == "bb/2026"
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

  describe "cycle_divergences/2" do
    test "flags a boleto whose Vencimento day differs from the account's due_day" do
      account = account_fixture(%{is_credit_card: true, due_day: 7})

      statement =
        statement_fixture(%{
          account: account,
          due_date: ~D[2026-06-16],
          source_file: "fatura.pdf"
        })

      assert [warning] = DirectoryImporter.cycle_divergences(account, [statement])

      assert warning == %{
               account_id: account.id,
               account_name: account.name,
               file: "fatura.pdf",
               file_due_day: 16,
               configured_due_day: 7
             }
    end

    test "returns [] when the Vencimento day matches the configured due_day" do
      account = account_fixture(%{is_credit_card: true, due_day: 16})
      statement = statement_fixture(%{account: account, due_date: ~D[2026-06-16]})

      assert DirectoryImporter.cycle_divergences(account, [statement]) == []
    end

    test "returns [] when the account has no configured due_day" do
      account = account_fixture(%{is_credit_card: true, due_day: nil})
      statement = statement_fixture(%{account: account, due_date: ~D[2026-06-16]})

      assert DirectoryImporter.cycle_divergences(account, [statement]) == []
    end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:event, e} -> collect_events([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/2 progress events" do
    test "emits start, per-account and per-file events in order", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_fixture(bank: "Bradesco", name: "Conta Corrente", parser_type: "bb_csv")

      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])
      account_folder(root, "brad", "Bradesco", "Conta Corrente", [{"e.csv", @bb_sample}])

      test_pid = self()

      DirectoryImporter.run(root,
        skip_installments: true,
        on_event: &send(test_pid, {:event, &1})
      )

      events = collect_events()

      assert [
               {:start, 2},
               {:account_start, "bb", 1},
               {:file_done, "bb"},
               {:account_done, %{imported: 3}},
               {:account_start, "brad", 1},
               {:file_done, "brad"},
               {:account_done, %{imported: 3}}
             ] = events
    end

    test "does not emit account events for unresolved folders", %{root: root} do
      account_folder(root, "bad", "Banco Fantasma", "Conta X", [{"e.csv", @bb_sample}])

      test_pid = self()

      DirectoryImporter.run(root,
        skip_installments: true,
        on_event: &send(test_pid, {:event, &1})
      )

      events = collect_events()

      assert [{:start, 1}] = events
    end

    test "works (and is unchanged) without on_event", %{root: root} do
      account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")
      account_folder(root, "bb", "Banco do Brasil", "Conta Corrente", [{"e.csv", @bb_sample}])

      assert %Result{accounts: [entry], warnings: [], errors: []} =
               DirectoryImporter.run(root, skip_installments: true)

      assert entry.imported == 3
    end
  end
end
