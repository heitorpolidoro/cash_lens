# CL-23 — Add the `/imports` route with the monitored-folder card and a colour-coded file list

Part 3 of 7 of the CL-8 decomposition, on top of CL-21 (`CashLens.Imports`, `imported_files`,
`import_runs` — all already shipped and **not** re-created here). This task builds the *shell*
of the dedicated import screen: the route, the sidebar entry, the monitored-folder card, and
the file list coloured by the status `Imports.scan/1` already computes.

## Scope

Covers:

- A new LiveView `CashLensWeb.ImportLive.Index` mounted at `live "/imports"`, inside the
  existing `live_session :default` so it gets the app layout and the `ActivePath` hook.
- A sidebar entry for `/imports` in `CashLensWeb.Layouts.nav_groups/1`.
- The monitored-folder card: shows the current root, lets the operator edit and persist it,
  and offers a scan/refresh button.
- The file list: one row per entry returned by `CashLens.Imports.scan/1`, labelled and coloured
  by its `:status`.
- Error and empty states for an unset, missing or invalid root.
- Two small additions to `CashLens.Imports` so the settings key never leaks into the web layer:
  `put_import_root/1` and `default_import_root/0`.
- `test/cash_lens_web/live/import_live_test.exs`.

Does **not** cover (each is its own task, see Out of Scope): pre-write inspection (CL-24), the
drag-and-drop dropzone (CL-25), the recent-import history panel (CL-26), any actual import
triggered from this screen, removal of the legacy import modals in `TransactionLive.Index`, and
any change to `scan/1`, the parsers, `DirectoryImporter` or the dedup rules.

## Approach

### Decisions (binding — no implementer discretion)

1. **The three statuses are not re-derived here.** `Imports.scan/1` already returns, per entry,
   `:status` ∈ `{:new, :updated, :synced}` computed from the `imported_files` row versus the
   on-disk `content_hash` and `mtime` (no row → `:new`; recorded hash **or** mtime differs from
   disk → `:updated`; both equal → `:synced`). This task **only maps** that atom to a label and
   a colour and must not re-implement, re-compare or second-guess it:
   - `:new` → `Novo`, green;
   - `:updated` → `Atualizado`, yellow/amber;
   - `:synced` → `Sincronizado`, grey/slate.
2. **What an `Atualizado` row shows.** `scan/1` returns only the *current disk* `content_hash`
   and `mtime` plus the recorded `last_imported_at` — it does not return the recorded hash. An
   `:updated` row therefore renders exactly: the first 8 characters of `entry.content_hash`
   (monospace, title/tooltip carrying the full 64-char hash), the disk `mtime`, and the
   `last_imported_at` of the recorded import, formatted `Calendar.strftime(dt, "%d/%m/%Y %H:%M")`.
   The copy makes the comparison explicit ("modificado em <mtime> · importado em
   <last_imported_at>"). `:synced` rows show only `last_imported_at`; `:new` rows show only the
   disk `mtime`. No row invents a "previous hash".
3. **The root is one value with one owner.** The screen reads the root through
   `CashLens.Imports.import_root([])` — the same function the recording path in
   `Ingestor`/`DirectoryImporter` uses — so the path the screen scans and the root that keys
   `imported_files.path` can never disagree. Writing goes through a new
   `CashLens.Imports.put_import_root/1`, which writes the **same** `"last_batch_import_path"`
   setting key through `CashLens.Settings.put/2`. That key literal must not appear anywhere in
   `lib/cash_lens_web/`. The legacy `BatchImportModalComponent` keeps reading/writing the same
   key and is not modified, so the two screens stay in sync by construction.
4. **Default fallback.** New `CashLens.Imports.default_import_root/0` returns
   `Application.get_env(:cash_lens, :default_import_root, "~/CashLens/extratos") |> Path.expand()`,
   with the default declared in `config/config.exs`. The screen's effective root is
   `Imports.import_root([]) || Imports.default_import_root()`; the default is **displayed and
   scanned but never silently persisted** — it becomes stored only when the operator saves it.
   When the root came from the default rather than from the setting, the card renders a hint
   telling the operator to save it, because until it is saved `Ingestor` keys new
   `imported_files` rows absolutely instead of root-relatively. (No data is lost either way:
   `scan/1` already looks entries up under both the relative and the absolute key.)
5. **`DirectoryImporter` is not involved.** This screen never imports anything. It only reads:
   `scan/1` internally reuses `DirectoryImporter.account_dirs/1` and `partition_files/2`, so the
   list shows exactly the files a batch import would consider — files outside a `.account` tree
   and files whose extension does not match the account's parser are absent, by CL-21's design,
   and this task does not add them back.
6. **Error and empty states** (the screen must never crash — `layout_navigation_test.exs`
   renders every nav path with no setting configured):
   - `scan/1` returns `{:error, :not_a_directory}` (missing, unmounted or non-directory root) →
     the file list area is replaced by an inline warning block carrying the text
     `Pasta não encontrada` and the offending path, plus the hint that a Google Drive mount may
     be offline. The card itself, its input and the scan button stay usable. No flash, no raise.
   - `{:ok, []}` (valid directory, nothing to list) → an empty-state block with the text
     `Nenhum arquivo encontrado` explaining that only folders marked with `.account` are listed.
   - Every state is distinguished in the DOM by a stable id: `#scan-error`, `#scan-empty`,
     `#file-list`.
7. **Persisting the path.** `phx-submit="save_path"` on the card form:
   - the value is `String.trim/1`-ed first;
   - **blank** → nothing is persisted, an `:error` flash `Informe um caminho.` is put, the form
     keeps the previous root;
   - **non-blank but not a directory** → the path **is** persisted anyway and an `:info` flash
     `Caminho salvo, mas a pasta não foi encontrada.` is shown, followed by the `#scan-error`
     state. This is deliberate: the monitored root is a Drive mount that is legitimately absent
     while unmounted, and refusing to store it would force a re-type on every remount;
   - **non-blank and a directory** → persisted, `:info` flash `Pasta monitorada salva.`, and the
     list is re-scanned immediately.
   `phx-change="validate_path"` only keeps the typed value in the assigns (no writes).
8. **Scanning** happens on `mount/3` and on the `"rescan"` event (a button in the card header).
   Both go through one private `assign_scan/2` so the two paths cannot drift. `"rescan"` also
   sets an `:info` flash `Pasta reescaneada.`. Scanning is synchronous; no Task, no PubSub.

### Behavior

- `GET /imports` returns 200 and renders: the page header, the monitored-folder card (current
  root in a text input, a `Salvar` submit, a `Reescanear` button) and the file list.
- The file list is a table with one row per `scan/1` entry, ordered as `scan/1` returns them
  (sorted by `path`). Each row shows the relative `path`, the `bank`/`account` of its
  `.account` folder, the status badge (decision 1) and the timestamps of decision 2.
- Each row carries `data-path={entry.path}` and `data-status={entry.status}` so tests and later
  parts can target rows without depending on the copy.
- A per-status counter ("3 novos · 1 atualizado · 12 sincronizados") sits in the list header.
- The markup leaves clearly commented, **empty** insertion points for the later parts — an HTML
  comment only, no dead controls: `<!-- CL-24: pre-write inspection action per row -->` inside
  the row action cell, `<!-- CL-25: universal dropzone -->` under the card, and
  `<!-- CL-26: recent import history -->` at the bottom of the page. Nothing in this task
  renders a button that does nothing.

### Files touched

- `lib/cash_lens_web/router.ex` — add `live "/imports", ImportLive.Index, :index` inside the
  existing `live_session :default`, in the import-related area of the scope.
- `lib/cash_lens_web/components/layouts.ex` — add
  `nav_item("Central de Importação", "/imports", "hero-arrow-down-tray", "/imports")` to the
  `Conciliação & Importação` group.
- `lib/cash_lens/imports.ex` — add `put_import_root/1` and `default_import_root/0` only;
  `scan/1`, `import_root/1` and every other existing function are untouched.
- `config/config.exs` — `config :cash_lens, :default_import_root, "~/CashLens/extratos"`.
- `lib/cash_lens_web/live/import_live/index.ex` — the new LiveView: `mount/3`,
  `handle_event/3` for `"validate_path"`, `"save_path"` and `"rescan"`, `render/1` with the
  card, the list, `#scan-error` and `#scan-empty`, following the structure and DaisyUI/Tailwind
  idiom of `lib/cash_lens_web/live/automation_live/bulk_ignore.ex`.
- `test/cash_lens_web/live/import_live_test.exs` — the new test module.

### Test criteria

`test/cash_lens_web/live/import_live_test.exs`, `use CashLensWeb.ConnCase, async: false`:

- **Settings isolation is mandatory**: `CashLens.Settings` writes a real `priv/settings.json`
  shared with the developer's environment, so `setup` captures
  `CashLens.Settings.get("last_batch_import_path", "")` and an `on_exit` writes it back
  verbatim. A test that leaves the developer's monitored folder changed is a failing test.
  The criterion is scoped to THIS suite: after `mix test
  test/cash_lens_web/live/import_live_test.exs`, that key's value must be byte-identical to
  its value before the run. It is deliberately not a whole-`mix test` assertion, because
  `batch_import_modal_component_test.exs:143` already persists a `batchclose_<n>` tmp path
  through `batch_import_modal_component.ex:58` and never restores it — a pre-existing leak
  this task neither causes nor is scoped to fix. `priv/settings.json` is gitignored
  (`.gitignore:35`), so `git status` is not a fallback check either.
- Fixtures follow `test/cash_lens/imports_test.exs`: a `System.tmp_dir!` root removed by
  `on_exit`, account folders written with a `.account` file, and an `account_fixture/1` whose
  bank/name/`parser_type` match it.
- Cases:
  1. `live(conn, ~p"/imports")` succeeds and the rendered HTML contains the configured root.
  2. Submitting the card form with a new existing directory persists it —
     `CashLens.Imports.import_root([]) == new_path` — and the re-rendered list shows a file from
     the new folder.
  3. Submitting a blank path leaves `import_root([])` unchanged and renders the error flash.
  4. Submitting an existing-but-not-a-directory path persists it and renders `#scan-error`
     without crashing.
  5. The three classifications, each asserted by selector, not by prose: a never-imported file
     → a row with `data-status="new"`; a file whose `imported_files` row matches disk (written
     with `Imports.upsert_imported_file/1` using `Imports.content_hash/1` and
     `Imports.file_mtime/1`) → `data-status="synced"`; the same file after its content is
     rewritten → `data-status="updated"`, and the rendered row contains the first 8 chars of the
     new disk hash.
  6. `"rescan"` picks up a file created after mount (row count grows) — proving the button
     re-runs `scan/1` rather than re-rendering stale assigns.
  7. A root that does not exist renders `#scan-error` and `Pasta não encontrada`.
- `test/cash_lens_web/live/layout_navigation_test.exs` keeps passing unchanged: it walks every
  nav entry and asserts `/imports` renders inside the layout, which is the regression guard for
  the unset-root case.
- `mix test test/cash_lens_web/live/import_live_test.exs test/cash_lens_web/live/layout_navigation_test.exs`
  passes, and `mix format --check-formatted` is clean.

## Expected Results

- [ ] `live "/imports", ImportLive.Index, :index` is registered in `CashLensWeb.Router` inside
      `live_session :default` and `GET /imports` responds 200
- [ ] `CashLensWeb.Layouts.nav_groups/1` contains an entry pointing at `/imports`, and the
      existing `layout_navigation_test.exs` still passes with it
- [ ] The monitored-folder card renders the root from `CashLens.Imports.import_root([])`,
      falling back to `CashLens.Imports.default_import_root/0` when the setting is unset
- [ ] Submitting the card form with a valid directory persists it, so a subsequent
      `CashLens.Imports.import_root([])` returns the saved path
- [ ] Submitting a blank path persists nothing and shows an error flash; submitting a
      non-existent path persists it and renders the `#scan-error` state without crashing
- [ ] A scan/refresh button re-runs `CashLens.Imports.scan/1` and re-renders the file list with
      files created since mount
- [ ] Each file row renders `data-status` of `new`, `updated` or `synced`, labelled Novo
      (green), Atualizado (yellow) and Sincronizado (grey)
- [ ] An `Atualizado` row shows the first 8 characters of the on-disk content hash and the disk
      mtime alongside the last import timestamp
- [ ] `scan/1` returning `{:error, :not_a_directory}` renders `#scan-error` with
      `Pasta não encontrada`, and `{:ok, []}` renders `#scan-empty`
- [ ] `test/cash_lens_web/live/import_live_test.exs` covers page render, persisting the edited
      path, the three classifications, the rescan button and the invalid-folder state, and
      passes under `mix test`
- [ ] After `mix test test/cash_lens_web/live/import_live_test.exs`, the
      `last_batch_import_path` value in `priv/settings.json` is byte-identical to its value
      before that run (this suite's own isolation; other suites' leakage is out of scope)
- [ ] `mix format --check-formatted` is clean, and `mix credo` reports no NEW findings in the
      files this task touches (pre-existing findings elsewhere in the repo are out of scope)
- [ ] No dropzone, no inspection modal and no history table is implemented; their insertion
      points exist only as HTML comments

## Out of Scope

- CL-24 pre-write inspection modal, CL-25 drag-and-drop dropzone, CL-26 recent-import history.
- Removing or redirecting the legacy import modals in `TransactionLive.Index` and the
  `Importar Extratos` topbar button.
- Any change to `Imports.scan/1`, the parsers, `DirectoryImporter`, `Ingestor` or the dedup
  and fingerprint rules.
- Triggering an import from `/imports`.

Interactive mockup: `docs/tasks/CL-23-mock.html`
