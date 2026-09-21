# CL-27 — Remove the legacy import modals from `TransactionLive` and point the import buttons at `/imports`

Part 7 of 7 of the CL-8 decomposition, and the last one: the cleanup that only makes sense
once CL-23 (the `/imports` shell), CL-24 (the pre-write inspection drawer), CL-25 (the
dropzone) and CL-26 (the history panel) have landed. This task **deletes** the two legacy
import modals, their wiring in `TransactionLive.Index`, their tests, and every remaining
entry point to them, and repoints the "Importar Extrato(s)" buttons at `/imports`.

It is a pure removal. It adds no feature, no new UI, no new module function and no behaviour
that did not already exist on `/imports`.

**No mock is warranted.** The only visual changes are two dropdown entries collapsing into
one link and two existing links changing their `href`/`navigate` target. There is no new
screen or state to review; `docs/tasks/CL-23-mock.html` through `CL-26-mock.html` already show
the `/imports` screen that replaces what is deleted here. A mock for CL-27 would add nothing,
so none is produced — deliberately, not by omission.

## Scope

Covers: deletion of `ImportModalComponent` and `BatchImportModalComponent` and their tests;
removal of every assign, `handle_event`, `handle_info` and template block in
`TransactionLive.Index` that exists only to serve them; removal of the
`?open_import=true` deep link and its handling; repointing the Dashboard, topbar and Extrato
import buttons to `~p"/imports"`; updating the tests that exercised the deleted paths.

Does **not** cover: any change to `CashLensWeb.ImportLive.Index`, `CashLens.Imports`,
`CashLens.Parsers.Ingestor`, `DirectoryImporter`, `FormatDetector`, the parsers, the dedup
rules, or the `mix cash_lens.import` / `mix cash_lens.backfill_statements` tasks. Does not
rename or delete the `"last_batch_import_path"` setting or `priv/settings.json`. Does not add
the installment re-scan to the `/imports` confirm path (see Parity, gap 1).

## Feature parity — what is lost, and what is not

Established before deleting anything. Each legacy capability, and where it lives afterwards:

| Legacy capability | Where it lives after CL-27 |
|---|---|
| Upload a statement file from the browser and import it | CL-25 dropzone on `/imports` |
| Choose the destination account explicitly | CL-25 `#drop-account` select |
| Format/parser detection | CL-25 via `FormatDetector` (by content, stronger than the legacy extension-only path) |
| Import files already on disk, per account folder | CL-23 file list + CL-24 `Inspecionar` → confirm |
| Persisted folder path (`last_batch_import_path`) | CL-23 monitored-folder card, same setting key |
| Preview-then-confirm before writing | CL-24 inspection drawer (per file, stricter: re-verifies the content hash at confirm) |
| Per-file / per-account progress reporting | Replaced by per-file confirm + CL-26 history panel |
| Result/error reporting after an import | CL-26 recent-imports panel (`import_runs`) |
| Missing-account report (`DirectoryImporter.preflight/1`) | `mix cash_lens.import`, and CL-23 simply does not list files under an unresolvable `.account` |

Two genuine gaps, both named here rather than deleted silently:

1. **Automatic installment grouping after a single-file import.**
   `import_modal_component.ex:129` calls `CashLens.Installments.scan_and_apply_all/0` after
   its batch of uploads, and `directory_importer.ex:98` does the same for folder imports. The
   `/imports` confirm path (CL-24/CL-25) calls `Ingestor.import_file/3` directly and does
   **not** run it. After this task, a single file imported through `/imports` leaves
   installments ungrouped until the operator triggers the existing re-scan in the Admin →
   Database screen (`admin_database_live.ex:153`) or runs `mix cash_lens.import`.
   CL-27 **must not** add the call — this is a removal task and the call would be new
   behaviour on a screen it does not own. The implementer records this in
   `docs/suggestions-log.md` as a follow-up ("run `Installments.scan_and_apply_all/0` after a
   confirmed import on `/imports`"); the decision to schedule it is the operator's.

2. **One-shot folder-wide import of every account.** The batch modal imported a whole tree in
   one click; `/imports` asks for one confirmation per file. The capability itself is not
   lost — `mix cash_lens.import <path>` uses the same `DirectoryImporter.preflight/1` +
   preview + confirm flow, and `DirectoryImporter` is untouched — but it is no longer
   available from the UI. Acceptable for a single-user local app; named here so the
   operator can object before the deletion lands.

3. **Bulk multi-file upload in one action.** `import_modal_component.ex:30` declares
   `max_entries: 100`, so today the operator can select up to 100 statement files and import
   them into one account in a single pass. CL-25 deliberately sets `max_entries: 1`
   (`docs/tasks/CL-25-spec.md`, the `allow_upload` declaration), because its whole design is
   one detection plus one inspection plus one explicit confirmation per file. After this task
   the same job becomes one drop and one confirmation per file. This is the largest of the
   three gaps in day-to-day effort and is named here so the operator can object before the
   deletion lands. CL-27 **must not** change `max_entries` — raising it belongs to CL-25's
   design, not to a removal task.

No other capability disappears. Three do, and they are the three above.

## Approach

### 1. Files deleted outright

Both component modules are deleted; nothing else in `lib/` references them after the comment
fix below.

- `lib/cash_lens_web/live/transaction_live/import_modal_component.ex`
- `lib/cash_lens_web/live/transaction_live/batch_import_modal_component.ex`
- `test/cash_lens_web/live/transaction_live/import_modal_component_test.exs`
- `test/cash_lens_web/live/transaction_live/import_modal_coverage_test.exs` (a wrapper
  LiveView that exists only to render `ImportModalComponent`)
- `test/cash_lens_web/live/transaction_live/batch_import_modal_component_test.exs`

Deleting `import_modal_component.ex` removes the project's second `allow_upload`, leaving
CL-25's `:drop` upload on `/imports` as the only one.

### 2. `lib/cash_lens_web/live/transaction_live/index.ex` — every removal, named

`mount/3` assigns (delete the four lines; `accounts` and `assign(:accounts, accounts)` stay):

- `:show_import_modal` (l.22), `:show_batch_import_modal` (l.23),
  `:import_account_id` (l.40), `:import_accounts` (l.57 — the
  `Enum.filter(accounts, & &1.accepts_import)` filter has no other reader; the component
  computed its own list via `assign_new`).

`handle_params/3`: delete the `{open_import, params} = Map.pop(params, "open_import")` line
(l.76) and the `|> assign(:show_import_modal, open_import == "true")` pipe (l.92).

`handle_event/3`: delete the whole `"open_import"` clause (l.296) and the whole
`"open_batch_import"` clause (l.301). In the `"close_modal"` clause (~l.385) delete only the
two `assign(:show_import_modal, false)` / `assign(:show_batch_import_modal, false)` pipes —
every other pipe in that clause serves a surviving modal and must stay.

`handle_info/2`: delete these clauses in full, with their `@impl true` attributes and the
comments attached to them —

- `:close_import_modal` (l.867), `:close_batch_import_modal` (l.872);
- `{:batch_import_progress, progress}` (l.877), `{:batch_import_finished, result, preview?, token}` (l.887);
- `{:import_file_start, index, total, filename}` (l.909), `{:import_file_parsed, n_lines}`,
  `{:import_file_done, cumulative_lines}`;
- both `{:import_success, ...}` clauses (the `failed: []` one and the `failed: failed` one);
- `{:import_error, reason}`.

After the deletions, `refresh_transactions_page1/2` and `Transactions.count_pending_transactions/0`
still have ~20 other callers and stay. The implementer verifies no alias or private helper in
`index.ex` became unused — the compiler warns, and `mix compile --warnings-as-errors` must be
clean for this file.

### 3. `lib/cash_lens_web/live/transaction_live/index.html.heex`

- Replace the two dropdown `<li>` entries at l.95–104 (`phx-click="open_import"` /
  `phx-click="open_batch_import"`) with a **single** `<li>` holding
  `<.link navigate={~p"/imports"}>` labelled `Importar Extratos` and keeping the
  `hero-arrow-up-tray` icon. The `sync_pluggy` and `auto_categorize_all` entries are untouched.
- Delete both `<.live_component>` blocks at l.1027–1038 (`import-modal` and
  `batch-import-modal`), including their `show={@show_import_modal}` /
  `show={@show_batch_import_modal}` attributes.

### 4. The other two `?open_import=true` entry points

- `lib/cash_lens_web/components/layouts/app.html.heex:50` — topbar quick action:
  `navigate={~p"/transactions?open_import=true"}` → `navigate={~p"/imports"}`. Label, title
  and icon unchanged.
- `lib/cash_lens_web/controllers/page_html/home.html.heex:13` — Dashboard:
  `href={~p"/transactions?open_import=true"}` → `href={~p"/imports"}`. Label unchanged.

### 5. The `"last_batch_import_path"` setting: ownership after the deletion

The value must survive — `/imports` reads it. It does, by construction:

- The setting lives in `priv/settings.json` (gitignored, local), which this task does not
  touch. Deleting code cannot delete a persisted value.
- `CashLens.Imports` already owns the key as `@root_setting "last_batch_import_path"`
  (`imports.ex:39`) and reads it through `import_root/1`; CL-23 added `put_import_root/1` for
  writing. After CL-27 the only two literal occurrences of the string in `lib/` are
  `imports.ex:39` and `lib/mix/tasks/cash_lens.backfill_statements.ex:28`. The web layer
  holds none — the last one (`batch_import_modal_component.ex:45`/`:58`) goes with the
  component.
- The key is **not** renamed and no migration of the value is performed.

**Pollution note.** `docs/suggestions-log.md:234` records that
`batch_import_modal_component_test.exs:143` persists a `batchclose_<n>` tmp path through
`batch_import_modal_component.ex:58` and never restores it. Deleting that test and that
component removes the only writer of the key in the test suite, so **yes — this task does fix
that pollution at the source**, and the implementer marks that suggestions-log entry resolved.
It does not clean a value already written into a developer's local `priv/settings.json`; the
CL-23 monitored-folder card displays and lets the operator correct it. The implementer checks
that no `/imports` test reintroduces the leak (any test persisting a root must restore the
previous value in `on_exit`).

### 6. Tests that exercised the deleted paths

- `test/cash_lens_web/live/transaction_live/index_test.exs` — contains no legacy-modal test
  today; verify none is added and that it passes unchanged. Add one assertion that the
  Extrato dropdown links to `/imports`.
- `index_coverage_test.exs` — `"close_modal event"` (l.121–131) opens the import modal to
  test closing: rewrite it against a surviving modal (e.g. `open_quick_category`), or delete
  it. `"handle_info import errors"` (l.103–108) targets the deleted `{:import_error, _}`
  clause: delete.
- `index_full_coverage_test.exs` — `"close_modal"` (l.306–313): same treatment as above.
  In the combined handle_info test (l.116–133) remove the `:close_import_modal`,
  `{:import_success, ...}` and `{:import_error, ...}` sends and their assertions; the
  surrounding transfer/reimbursement/category assertions stay.
- `index_handlers_test.exs` — delete the whole `describe "import progress handle_info"` block
  (l.134–151); both its tests target deleted clauses.
- `test/cash_lens_web/components/layouts_test.exs:132` — assert `href="/imports"` instead of
  `href="/transactions?open_import=true"`. The `"Importar Extratos"` label assertion at
  l.131 and `layout_navigation_test.exs:19` stay valid.

### 7. Deletion-completeness checklist (run by implementer and QA)

Each command must produce the stated output:

**Every grep below is scoped to `lib/` and `test/` deliberately.** Historical design
documents under `docs/superpowers/**` still mention both component modules and
`open_import`; those are a record of what was built and must stay. QA must not flag them.

1. `grep -rn "open_import" lib/ test/` → **no output**.
2. `grep -rn "ImportModalComponent\|BatchImportModalComponent" lib/ test/` → **no output**.
   Note `lib/cash_lens/parsers/ingestor.ex:424` mentions `ImportModalComponent` in a prose
   comment: reword it to refer to the batch import / `DirectoryImporter` instead.
3. `grep -rn "show_import_modal\|show_batch_import_modal\|import_account_id\|import_accounts" lib/ test/`
   → **no output**.
4. `grep -rn "close_import_modal\|close_batch_import_modal\|batch_import_progress\|batch_import_finished\|import_file_start\|import_file_parsed\|import_file_done\|import_success\|import_error" lib/ test/`
   → **no output**.
5. `ls lib/cash_lens_web/live/transaction_live/ | grep import` → **no output**.
6. `grep -rn "allow_upload" lib/` → exactly one hit, in `lib/cash_lens_web/live/import_live/index.ex`.
7. `grep -rn "last_batch_import_path" lib/` → exactly two hits: `lib/cash_lens/imports.ex`
   and `lib/mix/tasks/cash_lens.backfill_statements.ex`.

## Expected Results

- [ ] Both legacy import modals and all their wiring are gone from
      `lib/cash_lens_web/live/transaction_live/index.ex` and `index.html.heex`: the
      `show_import_modal`, `show_batch_import_modal`, `import_account_id` and
      `import_accounts` assigns, the `"open_import"` and `"open_batch_import"` events, the two
      `show_*_import_modal` pipes inside `"close_modal"`, and the `:close_import_modal`,
      `:close_batch_import_modal`, `{:batch_import_progress, _}`, `{:batch_import_finished, _, _, _}`,
      `{:import_file_start, _, _, _}`, `{:import_file_parsed, _}`, `{:import_file_done, _}`,
      both `{:import_success, _}` and `{:import_error, _}` `handle_info` clauses, plus both
      `<.live_component>` blocks
- [ ] `lib/cash_lens_web/live/transaction_live/import_modal_component.ex` and
      `batch_import_modal_component.ex` no longer exist, and
      `grep -rn "ImportModalComponent\|BatchImportModalComponent" lib/ test/` returns nothing
      (including the prose reference at `lib/cash_lens/parsers/ingestor.ex:424`)
- [ ] `grep -rn "open_import" lib/ test/` returns nothing
- [ ] The Dashboard button (`page_html/home.html.heex`), the topbar quick action
      (`layouts/app.html.heex`) and the Extrato screen dropdown entry
      (`transaction_live/index.html.heex`) all target `~p"/imports"`, and a request to
      `/transactions` renders no import modal markup
- [ ] `grep -rn "last_batch_import_path" lib/` returns exactly two hits —
      `lib/cash_lens/imports.ex` and `lib/mix/tasks/cash_lens.backfill_statements.ex` — and a
      root already stored in `priv/settings.json` is still read by `/imports` after the deletion
- [ ] `grep -rn "allow_upload" lib/` returns exactly one hit, in the `/imports` LiveView
- [ ] The legacy-modal tests are dropped or retargeted at a surviving modal:
      `import_modal_component_test.exs`, `import_modal_coverage_test.exs` and
      `batch_import_modal_component_test.exs` are deleted; `index_test.exs`,
      `index_coverage_test.exs`, `index_full_coverage_test.exs` and `index_handlers_test.exs`
      contain no reference to the removed events, messages or assigns and all pass;
      `layouts_test.exs` asserts `href="/imports"`
- [ ] `docs/suggestions-log.md` records that the `priv/settings.json` pollution
      (entry at `:234`) is resolved by the deletion of `batch_import_modal_component_test.exs`,
      and adds the installment-rescan parity gap as a follow-up
- [ ] `docker compose exec app mix test` passes with 0 failures across the
      whole project
- [ ] `mix format --check-formatted` is clean, `mix compile --warnings-as-errors` succeeds, and
      `mix credo` reports no NEW findings in the files this task touches (pre-existing findings
      elsewhere in the repo are out of scope)
- [ ] The task adds no new feature: no new LiveView, no new public function, no new UI element
      beyond the repointed links, and `lib/cash_lens_web/live/import_live/`,
      `lib/cash_lens/imports.ex`, `lib/cash_lens/parsers/` (beyond the one reworded comment)
      are otherwise unmodified

## Out of Scope

- Adding `Installments.scan_and_apply_all/0` to the `/imports` confirm path (parity gap 1 —
  logged as a follow-up, decided by the operator).
- Restoring a one-shot folder-wide import button in the UI (parity gap 2 — `mix cash_lens.import`
  covers it).
- Any change to `DirectoryImporter`, `Ingestor` behaviour, `FormatDetector`, the parsers or the
  dedup rules.
- Renaming `"last_batch_import_path"` or migrating its stored value.
- Cleaning pre-existing credo findings in files this task does not touch.
