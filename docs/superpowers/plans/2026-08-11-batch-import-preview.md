# Batch Import Preview Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before "Importar em Lote" writes anything, show the user a preview of how many transactions would be newly imported vs. already exist, per account, and only run the real (writing) import after they confirm.

**Architecture:** `Ingestor.import_file/3` gains a `:dry_run` option that reuses the exact same entry-preparation/fingerprint logic the real import uses, but only queries which fingerprints already exist instead of inserting — zero writes. `DirectoryImporter.run/2` threads the same option through every file it processes and skips installment scanning when dry-run. The batch-import LiveComponent gains two new phases (`:previewing`, `:preview_confirm`) between "accounts resolved" and "real import runs," and the parent LiveView's completion handler branches on whether the finished run was a preview or the real thing.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, ExUnit.

## Global Constraints

- Dry-run mode must produce **zero** writes: no `transactions` rows, no `credit_card_statements` rows, no balance rebuild, no transfer-rule/transfer-matcher/installment-detector runs.
- Dry-run counts must be computed via the exact same fingerprint logic the real import uses (`prepare_entries/3`, unchanged) — not an approximation — so the preview number and the real import's resulting number always match for the same input.
- The preview UI shows counts only, per account (`N novas`, `M já existem`, `K com falha`) — no per-transaction list.
- No database transaction spans the user's confirm/cancel click. Each phase (preview, then real import) is its own independent, complete operation.
- The existing "accounts missing, create them?" confirmation step (`:confirming` phase) is unchanged — it still creates missing accounts for real, immediately, before the (now-added) preview step runs.
- `"Cancelar"` on the new preview screen reuses the existing `"cancel_confirmation"` event (already resets to idle) rather than introducing a duplicate.

---

### Task 1: Dry-run support in `Ingestor` and `DirectoryImporter`

**Files:**
- Modify: `lib/cash_lens/parsers/ingestor.ex`
- Modify: `lib/cash_lens/parsers/directory_importer.ex`
- Test: `test/cash_lens/parsers/ingestor_test.exs`
- Test: `test/cash_lens/parsers/directory_importer_test.exs`

**Interfaces:**
- Produces: `Ingestor.import_file(account, file_path, dry_run: true)` — returns the same `{:ok, %{imported: n, skipped: n, failed: [...]}}` shape as a real call on the same input, but performs zero writes. `imported` means "would be newly imported"; `skipped` means "fingerprint already exists in `transactions`".
- Produces: `DirectoryImporter.run(path, dry_run: true, ...)` — same `%Result{}` shape as a real run, zero writes, does not call `CashLens.Installments.scan_and_apply_all/0`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cash_lens/parsers/ingestor_test.exs`, inside the existing `describe "import_file/2"` block (after its last test, before the block's closing `end` — check the file first to find that exact spot):

```elixir
    test "dry_run: true returns the same counts a real import would, with zero writes" do
      account = account_fixture(parser_type: "bb_csv")

      assert {:ok, %{imported: 3, skipped: 0, failed: []}} =
               Ingestor.import_file(account, @bb_sample, dry_run: true)

      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0

      assert {:ok, %{imported: 3, skipped: 0, failed: []}} =
               Ingestor.import_file(account, @bb_sample)

      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 3
    end

    test "dry_run: true reports rows already present as skipped, without inserting anything" do
      account = account_fixture(parser_type: "bb_csv")

      assert {:ok, %{imported: 3}} = Ingestor.import_file(account, @bb_sample)
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 3

      assert {:ok, %{imported: 0, skipped: 3, failed: []}} =
               Ingestor.import_file(account, @bb_sample, dry_run: true)

      # Still exactly 3 — the dry run above did not insert or delete anything.
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 3
    end

    test "dry_run: true does not create a credit-card statement" do
      # Statement creation is driven purely by `account.is_credit_card`, not
      # by file type (see the existing test right above this describe block,
      # "importing a credit-card file creates a statement and stamps
      # import_batch_id", which uses this exact same CSV+is_credit_card
      # combination for a REAL import) — so no PDF fixture is needed here.
      account = account_fixture(is_credit_card: true, parser_type: "bb_csv")

      assert {:ok, %{imported: 3}} = Ingestor.import_file(account, @bb_sample, dry_run: true)

      assert CashLens.Repo.aggregate(CashLens.CreditCards.Statement, :count) == 0
      assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0
    end
```

Add to `test/cash_lens/parsers/directory_importer_test.exs`, as a new `describe` block after the existing `describe "run/2 on a single account folder" do ... end` block (check the file to find where that block's closing `end` is, and add the new block right after it):

```elixir
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
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs test/cash_lens/parsers/directory_importer_test.exs`
Expected: FAIL — `:dry_run` isn't a recognized option yet, so these calls run a real (writing) import instead, and the "zero writes" assertions fail.

- [ ] **Step 3: Add `:dry_run` support to `Ingestor`**

In `lib/cash_lens/parsers/ingestor.ex`, add this import right after the existing `alias` lines (after `alias Ecto.UUID`):

```elixir
  import Ecto.Query, only: [from: 2]
```

Replace the existing `import_file/3`:

```elixir
  @doc """
  Reads a file, converts encoding/extracts text, parses and saves the transactions.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def import_file(account, file_path, opts \\ []) do
    notify_fn = Keyword.get(opts, :notify_fn)

    case File.read(file_path) do
      {:ok, content} ->
        process_imported_content(content, account, file_path, notify_fn)

      {:error, reason} ->
        {:error, "Could not read file: #{reason}"}
    end
  end
```

with:

```elixir
  @doc """
  Reads a file, converts encoding/extracts text, parses and saves the transactions.
  Returns `{:ok, count}` or `{:error, reason}`.

  With `dry_run: true`, computes the same `%{imported:, skipped:, failed:}`
  a real call on the same input would return, using the same fingerprint
  logic, but performs zero writes (no transaction rows, no credit-card
  statement, no balance rebuild).
  """
  def import_file(account, file_path, opts \\ []) do
    notify_fn = Keyword.get(opts, :notify_fn)
    dry_run = Keyword.get(opts, :dry_run, false)

    case File.read(file_path) do
      {:ok, content} ->
        process_imported_content(content, account, file_path, notify_fn, dry_run)

      {:error, reason} ->
        {:error, "Could not read file: #{reason}"}
    end
  end
```

Replace the existing `process_imported_content/4`:

```elixir
  defp process_imported_content(content, account, file_path, notify_fn) do
    content = prepare_content(content, account, file_path)

    Logger.info("INGESTOR: #{account.parser_type} <- #{file_path} (#{account.name})")

    case parse(content, account.parser_type) do
      {:error, reason} ->
        Logger.error("INGESTOR: Parsing failed: #{reason}")
        {:error, reason}

      transactions_data ->
        Logger.info("INGESTOR: Parser returned #{length(transactions_data)} transactions.")
        if notify_fn, do: notify_fn.(length(transactions_data))

        statement_id =
          maybe_create_statement(account, content, file_path, transactions_data)

        finalize_import(transactions_data, account.id, statement_id)
    end
  end
```

with:

```elixir
  defp process_imported_content(content, account, file_path, notify_fn, dry_run) do
    content = prepare_content(content, account, file_path)

    Logger.info("INGESTOR: #{account.parser_type} <- #{file_path} (#{account.name})")

    case parse(content, account.parser_type) do
      {:error, reason} ->
        Logger.error("INGESTOR: Parsing failed: #{reason}")
        {:error, reason}

      transactions_data ->
        Logger.info("INGESTOR: Parser returned #{length(transactions_data)} transactions.")
        if notify_fn, do: notify_fn.(length(transactions_data))

        if dry_run do
          preview_import(transactions_data, account.id)
        else
          statement_id =
            maybe_create_statement(account, content, file_path, transactions_data)

          finalize_import(transactions_data, account.id, statement_id)
        end
    end
  end
```

Add these two new private functions right after `finalize_import/3` (before `defp prepare_entries`):

```elixir
  # Computes what a real import would do — same future-date filtering and
  # same `prepare_entries/3` (and therefore the same real dedup fingerprint)
  # `finalize_import/3` uses — but performs zero writes: no statement, no
  # transaction rows, no balance rebuild, no transfer/installment linking.
  # `imported` here means "would be newly imported"; `skipped` means "already
  # present" (a fingerprint that already exists in `transactions`) — the same
  # meaning `finalize_import/3`'s `on_conflict: :nothing` insert would
  # produce for the same input.
  defp preview_import(transactions_data, account_id) do
    today = Date.utc_today()
    transactions_data = Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))

    {entries, failed} = prepare_entries(transactions_data, account_id, nil)

    already_present = existing_fingerprints(Enum.map(entries, & &1.fingerprint))
    new_count = Enum.count(entries, &(&1.fingerprint not in already_present))

    {:ok, %{imported: new_count, skipped: length(entries) - new_count, failed: failed}}
  end

  defp existing_fingerprints([]), do: MapSet.new()

  defp existing_fingerprints(fingerprints) do
    CashLens.Repo.all(
      from(t in Transaction, where: t.fingerprint in ^fingerprints, select: t.fingerprint)
    )
    |> MapSet.new()
  end
```

- [ ] **Step 4: Add `:dry_run` support to `DirectoryImporter`**

In `lib/cash_lens/parsers/directory_importer.ex`, replace the `@doc` and `run/2`/`run_existing/2`:

```elixir
  @doc """
  Imports a directory. Options:
    * `:skip_installments` — when true, does not run installment detection
      (used in tests to keep cases isolated).
    * `:create_missing` — when true, creates accounts referenced in `.account`
      files that do not yet exist in the database (call `preflight/1` first and
      confirm with the user before passing this option).
  """
  def run(path, opts \\ []) do
    if File.dir?(path) do
      run_existing(path, opts)
    else
      %Result{errors: ["caminho '#{path}' não existe ou não é uma pasta"]}
    end
  end

  defp run_existing(path, opts) do
    if Keyword.get(opts, :create_missing, false) do
      create_missing_accounts(path)
    end

    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    {account_dirs, skipped_dirs} = classify(path)

    emit.({:start, length(account_dirs)})

    result =
      account_dirs
      |> Enum.reduce(%Result{}, fn dir, acc -> import_account_folder(dir, path, acc, emit) end)
      |> add_skipped_warnings(skipped_dirs)

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end
```

with:

```elixir
  @doc """
  Imports a directory. Options:
    * `:skip_installments` — when true, does not run installment detection
      (used in tests to keep cases isolated).
    * `:create_missing` — when true, creates accounts referenced in `.account`
      files that do not yet exist in the database (call `preflight/1` first and
      confirm with the user before passing this option).
    * `:dry_run` — when true, computes the same per-account counts a real run
      would, with zero writes (no transactions, no statements, no balance
      rebuild, no installment scan — regardless of `:skip_installments`).
  """
  def run(path, opts \\ []) do
    if File.dir?(path) do
      run_existing(path, opts)
    else
      %Result{errors: ["caminho '#{path}' não existe ou não é uma pasta"]}
    end
  end

  defp run_existing(path, opts) do
    if Keyword.get(opts, :create_missing, false) do
      create_missing_accounts(path)
    end

    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    dry_run = Keyword.get(opts, :dry_run, false)
    {account_dirs, skipped_dirs} = classify(path)

    emit.({:start, length(account_dirs)})

    result =
      account_dirs
      |> Enum.reduce(%Result{}, fn dir, acc ->
        import_account_folder(dir, path, acc, emit, dry_run)
      end)
      |> add_skipped_warnings(skipped_dirs)

    unless dry_run or Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end
```

Replace `import_account_folder/4`:

```elixir
  defp import_account_folder(dir, root_path, result, emit) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, root_path, account, bank, name, result, emit)
    else
      {:error, reason} ->
        add_error(result, "pasta #{Path.basename(dir)}/ — #{reason}")
    end
  end
```

with:

```elixir
  defp import_account_folder(dir, root_path, result, emit, dry_run) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, root_path, account, bank, name, result, emit, dry_run)
    else
      {:error, reason} ->
        add_error(result, "pasta #{Path.basename(dir)}/ — #{reason}")
    end
  end
```

Replace `do_import/7`:

```elixir
  defp do_import(dir, root_path, account, bank, name, result, emit) do
    label = format_label(dir, root_path)
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, mismatched} = partition_files(dir, expected)

    result =
      Enum.reduce(mismatched, result, fn file, acc ->
        add_warning(
          acc,
          "arquivo #{Path.basename(file)} não corresponde ao parser #{account.parser_type} — ignorado"
        )
      end)

    emit.({:account_start, label, length(matching)})

    summary =
      Enum.reduce(matching, %{imported: 0, skipped: 0, failed: []}, fn file, acc ->
        acc =
          case Ingestor.import_file(account, file) do
            {:ok, s} ->
              %{
                imported: acc.imported + s.imported,
                skipped: acc.skipped + Map.get(s, :skipped, 0),
                failed: acc.failed ++ Map.get(s, :failed, [])
              }

            {:error, reason} ->
              %{acc | failed: acc.failed ++ [{Path.basename(file), reason}]}
          end

        emit.({:file_done, label})
        acc
      end)

    emit.({:account_done, summary})

    entry = Map.merge(summary, %{account: account, bank: bank, name: name, folder_path: label})

    statements = CashLens.CreditCards.list_boletos_for_account(account.id)
    divergences = cycle_divergences(account, statements)

    %{
      result
      | accounts: result.accounts ++ [entry],
        cycle_warnings: result.cycle_warnings ++ divergences
    }
  end
```

with:

```elixir
  defp do_import(dir, root_path, account, bank, name, result, emit, dry_run) do
    label = format_label(dir, root_path)
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, mismatched} = partition_files(dir, expected)

    result =
      Enum.reduce(mismatched, result, fn file, acc ->
        add_warning(
          acc,
          "arquivo #{Path.basename(file)} não corresponde ao parser #{account.parser_type} — ignorado"
        )
      end)

    emit.({:account_start, label, length(matching)})

    summary =
      Enum.reduce(matching, %{imported: 0, skipped: 0, failed: []}, fn file, acc ->
        acc =
          case Ingestor.import_file(account, file, dry_run: dry_run) do
            {:ok, s} ->
              %{
                imported: acc.imported + s.imported,
                skipped: acc.skipped + Map.get(s, :skipped, 0),
                failed: acc.failed ++ Map.get(s, :failed, [])
              }

            {:error, reason} ->
              %{acc | failed: acc.failed ++ [{Path.basename(file), reason}]}
          end

        emit.({:file_done, label})
        acc
      end)

    emit.({:account_done, summary})

    entry = Map.merge(summary, %{account: account, bank: bank, name: name, folder_path: label})

    statements = CashLens.CreditCards.list_boletos_for_account(account.id)
    divergences = cycle_divergences(account, statements)

    %{
      result
      | accounts: result.accounts ++ [entry],
        cycle_warnings: result.cycle_warnings ++ divergences
    }
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cash_lens/parsers/ingestor_test.exs test/cash_lens/parsers/directory_importer_test.exs`
Expected: all tests PASS, including the new dry-run ones.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (3 failures in `test/cash_lens_web/live/installment_live_test.exs`, date-sensitive fixtures) — no new failures. This also confirms every other `Ingestor.import_file/2,3` and `DirectoryImporter.run/1,2` caller in the codebase (the `mix cash_lens.import` task, the backfill task) still works with the now-5-arity `import_account_folder` and `do_import` — since both are `defp`, only call sites inside this same file matter, but a full-suite pass is the check that nothing external broke.

- [ ] **Step 7: Commit**

```bash
git add lib/cash_lens/parsers/ingestor.ex lib/cash_lens/parsers/directory_importer.ex test/cash_lens/parsers/ingestor_test.exs test/cash_lens/parsers/directory_importer_test.exs
git commit -m "feat(parsers): add dry_run option to Ingestor and DirectoryImporter"
```

---

### Task 2: Preview confirmation UI in the batch import modal

**Files:**
- Modify: `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex`
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex`
- Test: `test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`

**Interfaces:**
- Consumes: `Ingestor.import_file(account, file_path, dry_run: true)` and `DirectoryImporter.run(path, dry_run: true, ...)` from Task 1 — same `%{imported:, skipped:, failed:}` / `%DirectoryImporter.Result{}` shapes as a real run.
- Produces: two new `@batch_progress.phase` values the component's `render/1` switches on: `:previewing` (reuses the existing `progress_view/1`, now driven by a `preview?` boolean in the progress map) and `:preview_confirm` (new `preview_confirm_view/1`).
- Produces: the `{:batch_import_finished, result, preview?}` message shape (was `{:batch_import_finished, result}`) — sent from the component, received in `CashLensWeb.TransactionLive.Index.handle_info/2`.

- [ ] **Step 1: Write the failing tests**

Add this new test to `test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`, after its existing test (inside the same module, before the closing `end`):

```elixir
  test "a completed preview shows per-account counts and offers confirm/cancel", %{conn: conn} do
    account = account_fixture(bank: "Banco Teste", name: "Conta Teste")

    result = %DirectoryImporter.Result{
      accounts: [
        %{
          account: account,
          bank: account.bank,
          name: account.name,
          folder_path: "conta-teste",
          imported: 3,
          skipped: 1,
          failed: []
        }
      ]
    }

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :preview_confirm, result: result}
    )

    html = render(index_live)
    assert html =~ "conta-teste"
    assert html =~ "3 novas"
    assert html =~ "1 já existem"
    assert html =~ "Confirmar Importação"
    assert html =~ "Cancelar"
  end

  test "cancelling a preview returns to the idle path form with no writes", %{conn: conn} do
    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    Phoenix.LiveView.send_update(
      index_live.pid,
      CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :preview_confirm, result: %DirectoryImporter.Result{}}
    )

    html =
      index_live
      |> element("button[phx-click='cancel_confirmation']")
      |> render_click()

    assert html =~ "Caminho da Pasta"
    refute html =~ "Confirmar Importação"
  end

  test "submitting a path with all accounts already present previews before importing", %{
    conn: conn
  } do
    account_fixture(bank: "Banco do Brasil", name: "Conta Corrente", parser_type: "bb_csv")

    root = Path.join(System.tmp_dir!(), "batchpreview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, ".account"), "bank: Banco do Brasil\naccount: Conta Corrente\n")

    File.write!(
      Path.join(root, "extrato.csv"),
      File.read!("test/support/fixtures/files/bb_sample.csv")
    )

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_batch_import")

    index_live
    |> form("#batch-import-form", %{"path" => root})
    |> render_submit()

    # The load-bearing assertion: submitting alone must never write, whether
    # the render caught the brief ":previewing" progress state or already
    # settled on ":preview_confirm" by the time this returns (both are valid
    # — `:sql_sandbox` mode runs the dry-run inline, so exactly which of the
    # two the returned HTML reflects is a timing detail, not the behavior
    # under test). `render/1` after a moment lets any queued
    # `:batch_import_finished` message be processed, then checks the
    # settled screen.
    html = render(index_live)
    assert html =~ "novas" or html =~ "Calculando Pré-visualização..."
    assert CashLens.Repo.aggregate(CashLens.Transactions.Transaction, :count) == 0
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`
Expected: FAIL — `:preview_confirm` isn't a recognized phase yet (renders the fallback path form instead), and submitting a path goes straight to a real import rather than a preview.

- [ ] **Step 3: Update `BatchImportModalComponent`**

In `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex`, replace the `@idle_progress` module attribute:

```elixir
  @idle_progress %{
    phase: :idle,
    total_accounts: 0,
    accounts_done: 0,
    current_account: nil,
    current_account_file_index: 0,
    current_account_file_total: 0,
    result: nil,
    missing_accounts: []
  }
```

with:

```elixir
  @idle_progress %{
    phase: :idle,
    total_accounts: 0,
    accounts_done: 0,
    current_account: nil,
    current_account_file_index: 0,
    current_account_file_total: 0,
    result: nil,
    missing_accounts: [],
    preview?: false
  }
```

Replace the `handle_event("start_batch_import", ...)` clause:

```elixir
  @impl true
  def handle_event("start_batch_import", %{"path" => path}, socket) do
    path = String.trim(path)
    CashLens.Settings.put("last_batch_import_path", path)
    socket = assign(socket, :batch_path, path)

    case DirectoryImporter.preflight(path) do
      :ok ->
        socket = assign(socket, :batch_progress, %{@idle_progress | phase: :importing})
        start_batch_import(path, create_missing: false)
        {:noreply, socket}

      {:needs_confirmation, missing_accounts} ->
        progress = %{@idle_progress | phase: :confirming, missing_accounts: missing_accounts}
        {:noreply, assign(socket, :batch_progress, progress)}

      {:error, reasons} ->
        result = %DirectoryImporter.Result{errors: reasons}
        progress = %{@idle_progress | phase: :done, result: result}
        {:noreply, assign(socket, :batch_progress, progress)}
    end
  end
```

with:

```elixir
  @impl true
  def handle_event("start_batch_import", %{"path" => path}, socket) do
    path = String.trim(path)
    CashLens.Settings.put("last_batch_import_path", path)
    socket = assign(socket, :batch_path, path)

    case DirectoryImporter.preflight(path) do
      :ok ->
        socket =
          assign(socket, :batch_progress, %{@idle_progress | phase: :previewing, preview?: true})

        start_batch_import(path, [dry_run: true], true)
        {:noreply, socket}

      {:needs_confirmation, missing_accounts} ->
        progress = %{@idle_progress | phase: :confirming, missing_accounts: missing_accounts}
        {:noreply, assign(socket, :batch_progress, progress)}

      {:error, reasons} ->
        result = %DirectoryImporter.Result{errors: reasons}
        progress = %{@idle_progress | phase: :done, result: result}
        {:noreply, assign(socket, :batch_progress, progress)}
    end
  end
```

Replace the `handle_event("confirm_create_accounts", ...)` clause:

```elixir
  @impl true
  def handle_event("confirm_create_accounts", _params, socket) do
    path = socket.assigns.batch_path
    socket = assign(socket, :batch_progress, %{@idle_progress | phase: :importing})
    start_batch_import(path, create_missing: true)
    {:noreply, socket}
  end
```

with:

```elixir
  @impl true
  def handle_event("confirm_create_accounts", _params, socket) do
    path = socket.assigns.batch_path

    socket =
      assign(socket, :batch_progress, %{@idle_progress | phase: :previewing, preview?: true})

    start_batch_import(path, [create_missing: true, dry_run: true], true)
    {:noreply, socket}
  end
```

Add a new `handle_event("confirm_import", ...)` clause right after it:

```elixir
  @impl true
  def handle_event("confirm_import", _params, socket) do
    path = socket.assigns.batch_path
    socket = assign(socket, :batch_progress, %{@idle_progress | phase: :importing})
    start_batch_import(path, [dry_run: false], false)
    {:noreply, socket}
  end
```

Replace `start_batch_import/2`:

```elixir
  defp start_batch_import(path, extra_opts) do
    pid = self()

    process_import = fn ->
      {:ok, agent} =
        Agent.start_link(fn ->
          %{total_accounts: 0, accounts_done: 0, current_file_index: 0}
        end)

      try do
        opts = Keyword.merge(extra_opts, on_event: build_on_event(pid, agent))
        result = DirectoryImporter.run(path, opts)
        send(pid, {:batch_import_finished, result})
      rescue
        # coveralls-ignore-start — defensive guard so a crash inside the import Task
        # surfaces to the UI instead of dying silently; not deterministically testable.
        e ->
          error_result = %DirectoryImporter.Result{
            errors: ["Erro inesperado: #{Exception.message(e)}"]
          }

          send(pid, {:batch_import_finished, error_result})
          # coveralls-ignore-stop
      after
        Agent.stop(agent)
      end
    end

    if Application.get_env(:cash_lens, :sql_sandbox) do
      process_import.()
    else
      task_start = Application.get_env(:cash_lens, :task_start_fn, &Task.start/1)
      task_start.(process_import)
    end
  end
```

with:

```elixir
  defp start_batch_import(path, extra_opts, preview?) do
    pid = self()

    process_import = fn ->
      {:ok, agent} =
        Agent.start_link(fn ->
          %{total_accounts: 0, accounts_done: 0, current_file_index: 0}
        end)

      try do
        opts = Keyword.merge(extra_opts, on_event: build_on_event(pid, agent))
        result = DirectoryImporter.run(path, opts)
        send(pid, {:batch_import_finished, result, preview?})
      rescue
        # coveralls-ignore-start — defensive guard so a crash inside the import Task
        # surfaces to the UI instead of dying silently; not deterministically testable.
        e ->
          error_result = %DirectoryImporter.Result{
            errors: ["Erro inesperado: #{Exception.message(e)}"]
          }

          send(pid, {:batch_import_finished, error_result, preview?})
          # coveralls-ignore-stop
      after
        Agent.stop(agent)
      end
    end

    if Application.get_env(:cash_lens, :sql_sandbox) do
      process_import.()
    else
      task_start = Application.get_env(:cash_lens, :task_start_fn, &Task.start/1)
      task_start.(process_import)
    end
  end
```

Replace the `render/1` `case` block (inside the existing `render/1` function, only the `<%= case ... %>` body changes):

```elixir
          <%= case @batch_progress.phase do %>
            <% :importing -> %>
              <.progress_view progress={@batch_progress} />
            <% :confirming -> %>
              <.confirm_create_view
                missing_accounts={@batch_progress.missing_accounts}
                myself={@myself}
              />
            <% :done -> %>
              <.result_view result={@batch_progress.result} myself={@myself} />
            <% _ -> %>
              <.path_form myself={@myself} batch_path={@batch_path} />
          <% end %>
```

with:

```elixir
          <%= case @batch_progress.phase do %>
            <% phase when phase in [:previewing, :importing] -> %>
              <.progress_view progress={@batch_progress} />
            <% :preview_confirm -> %>
              <.preview_confirm_view result={@batch_progress.result} myself={@myself} />
            <% :confirming -> %>
              <.confirm_create_view
                missing_accounts={@batch_progress.missing_accounts}
                myself={@myself}
              />
            <% :done -> %>
              <.result_view result={@batch_progress.result} myself={@myself} />
            <% _ -> %>
              <.path_form myself={@myself} batch_path={@batch_path} />
          <% end %>
```

Replace the `progress_view/1` heading line:

```elixir
  defp progress_view(assigns) do
    ~H"""
    <div class="py-2 space-y-6 min-h-[200px]">
      <h2 class="text-2xl font-black uppercase tracking-tighter text-primary">
        Importando em Lote...
      </h2>
```

with:

```elixir
  defp progress_view(assigns) do
    ~H"""
    <div class="py-2 space-y-6 min-h-[200px]">
      <h2 class="text-2xl font-black uppercase tracking-tighter text-primary">
        {if @progress.preview?, do: "Calculando Pré-visualização...", else: "Importando em Lote..."}
      </h2>
```

Add this new function component right after `confirm_create_view/1` (before `progress_view/1`):

```elixir
  defp preview_confirm_view(assigns) do
    ~H"""
    <div>
      <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
        Confirmar Importação
      </h2>
      <p class="text-sm opacity-60 mb-4">
        Revise quantas transações seriam importadas antes de gravar no banco.
      </p>

      <div class="max-h-80 overflow-y-auto space-y-2 mb-6">
        <div
          :for={account <- @result.accounts}
          class="p-3 bg-base-200/50 rounded-xl border border-base-300"
        >
          <div class="flex items-center gap-2">
            <.icon name="hero-folder-open" class="size-4 text-primary shrink-0" />
            <span class="text-sm font-bold truncate">{account.folder_path}</span>
          </div>
          <p class="text-xs opacity-60 ml-6">
            {account.imported} novas
            <%= if account.skipped > 0 do %>
              , {account.skipped} já existem
            <% end %>
            <%= if account.failed != [] do %>
              , {length(account.failed)} com falha
            <% end %>
          </p>
        </div>

        <div :for={warning <- @result.warnings} class="flex items-center gap-2 text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <span class="text-xs">{warning}</span>
        </div>

        <div :for={error <- @result.errors} class="flex items-center gap-2 text-error">
          <.icon name="hero-x-circle" class="size-4 shrink-0" />
          <span class="text-xs">{error}</span>
        </div>
      </div>

      <div class="flex gap-3">
        <button
          phx-click="confirm_import"
          phx-target={@myself}
          class="btn btn-primary btn-lg flex-1 rounded-2xl"
        >
          Confirmar Importação
        </button>
        <button
          phx-click="cancel_confirmation"
          phx-target={@myself}
          class="btn btn-ghost btn-lg rounded-2xl"
        >
          Cancelar
        </button>
      </div>
    </div>
    """
  end
```

- [ ] **Step 4: Update the parent LiveView's completion handler**

In `lib/cash_lens_web/live/transaction_live/index.ex`, replace:

```elixir
  @impl true
  def handle_info({:batch_import_finished, result}, socket) do
    send_update(CashLensWeb.TransactionLive.BatchImportModalComponent,
      id: "batch-import-modal",
      progress_update: %{phase: :done, result: result}
    )

    {:noreply,
     socket
     |> assign(:pending_count, Transactions.count_pending_transactions())
     |> refresh_transactions_page1(socket.assigns.filters)}
  end
```

with:

```elixir
  @impl true
  def handle_info({:batch_import_finished, result, preview?}, socket) do
    if preview? do
      send_update(CashLensWeb.TransactionLive.BatchImportModalComponent,
        id: "batch-import-modal",
        progress_update: %{phase: :preview_confirm, result: result}
      )

      {:noreply, socket}
    else
      send_update(CashLensWeb.TransactionLive.BatchImportModalComponent,
        id: "batch-import-modal",
        progress_update: %{phase: :done, result: result}
      )

      {:noreply,
       socket
       |> assign(:pending_count, Transactions.count_pending_transactions())
       |> refresh_transactions_page1(socket.assigns.filters)}
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`
Expected: all tests PASS, including the new ones and the pre-existing cycle-divergence test.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (3 failures in `test/cash_lens_web/live/installment_live_test.exs`) — no new failures.

- [ ] **Step 7: Manually verify in the browser**

Start the dev server and open the Transactions screen, "Ações" → "Importar em Lote":
- Submit a path where all accounts already exist — confirm it shows "Calculando Pré-visualização..." briefly, then a per-account "N novas / M já existem" summary with **Confirmar Importação** / **Cancelar** buttons, and that nothing changed in the Transactions list yet.
- Click **Cancelar** — confirm it returns to the empty path form, and the Transactions list is still unchanged.
- Submit the same path again and click **Confirmar Importação** — confirm it now shows "Importando em Lote..." (the real, writing import), finishes on the existing "Importação Concluída" screen, and the counts match what the preview said.
- Submit a path with a missing account — confirm the existing "Contas não encontradas" screen still appears; click "Criar e importar" — confirm it now also lands on the preview screen (not straight into a real import), and confirming from there performs the real import.

- [ ] **Step 8: Commit**

```bash
git add lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex lib/cash_lens_web/live/transaction_live/index.ex test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs
git commit -m "feat(transactions): preview batch import counts before writing"
```

---

## Plan Self-Review Notes

- **Spec coverage:** dry-run mechanism (zero writes, same fingerprint logic, skips installment scan) is Task 1; the full UI flow (preview after preflight success, preview after account creation, confirm → real import, cancel → idle, counts-only per-account display) is Task 2. Every spec testing bullet has a corresponding test. Covered.
- **Type consistency:** `Ingestor.import_file/3`'s `dry_run` option and its `{:ok, %{imported:, skipped:, failed:}}` return shape are identical in dry-run and real mode — Task 2's UI code never needs to distinguish them, it just reads `account.imported`/`account.skipped`/`account.failed` the same way `result_view/1` already does today. The `{:batch_import_finished, result, preview?}` message shape is produced once (in `start_batch_import/3`) and consumed once (in `Index.handle_info/2`) — no other call site exists (verified via grep before writing this plan).
- **No placeholders:** every step has runnable code or an exact command. Caught and fixed one vacuous test during self-review: an earlier draft of Task 1 Step 1's third test wrote a PDF fixture file but never actually called `Ingestor.import_file/3`, so it asserted nothing about dry-run behavior. Replaced with a real test that calls the function under test, reusing the existing `is_credit_card: true` + `bb_csv` CSV pattern already proven in this file's neighboring "creates a statement" test — no PDF fixture needed, since statement creation is driven by `account.is_credit_card`, not file type.
