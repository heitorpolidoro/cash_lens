# CL-26 — Recent-imports history panel on `/imports`

Part 6 of 7 of the CL-8 decomposition, on top of CL-21 (`CashLens.Imports`, `imported_files`,
`import_runs`, `list_recent_runs/1` — all already shipped) and CL-23 (the `/imports` screen
shell). This task fills the insertion point CL-23 left at the bottom of the page
(`<!-- CL-26: recent import history -->`) with a read-only table of the most recent executed
imports.

## Scope

Covers:

- A recent-imports panel at the bottom of `CashLensWeb.ImportLive.Index`, rendering the rows
  returned by `CashLens.Imports.list_recent_runs/1`.
- Status badges, human-readable file labels, account labels, counts and the error message.
- The panel's empty state, and refreshing it after a confirmed import and on rescan.
- New cases in `test/cash_lens_web/live/import_live_test.exs`.

Does **not** cover: any change to `CashLens.Imports` (`list_recent_runs/1` exists as needed and
is used as-is), to `Ingestor.record_import/5`, to the `import_runs` schema or its migration, to
the dropzone (CL-25), to the inspection drawer (CL-24), or removal of the legacy import modals
in `TransactionLive.Index` (CL-27). The panel writes nothing — it is a pure read.

## Approach

### Decisions (binding — no implementer discretion)

**1. The status vocabulary is exactly three values, all verified in the code.**
`CashLens.Imports.ImportRun` declares `@statuses ~w(success warning error)` and
`validate_inclusion/3` rejects anything else (`test/cash_lens/imports_test.exs:312` asserts
`"partial"` is refused). All three are actually written, from the three `record_import/5` call
sites in `lib/cash_lens/parsers/ingestor.ex`:

- `ingestor.ex:98` (unreadable file) and `ingestor.ex:160` (parse failure) → `run_attrs/5`'s
  `{:error, reason}` clause → `status: "error"`, counts `0/0/0`, `error_message` set;
- `ingestor.ex:175` (real, non-dry-run finalization) → the `{:ok, summary}` clause →
  `status: if(summary.failed == [], do: "success", else: "warning")`.

The badge mapping is therefore total over the stored vocabulary:

| `status`   | Label      | Colour            |
|------------|------------|-------------------|
| `"success"`| `Sucesso`  | green             |
| `"warning"`| `Aviso`    | yellow/amber      |
| `"error"`  | `Erro`     | red               |

The badge helper carries a final catch-all clause so an unknown value can never crash the
screen: any other string renders a **grey** badge whose label is the raw stored value. This is
a defensive fallback for data written outside the changeset (a manual SQL row, a future
status), not a supported state.

**2. `account` is nullable and must render as such.** `import_runs.account_id` is
`references(:accounts, on_delete: :nilify_all)` and carries no `null: false`
(`priv/repo/migrations/20260919120100_create_import_runs.exs`), and the changeset does not
require it. Every current writer passes `account.id`, so in practice `nil` means *the account
was deleted after the run*. The Conta cell then renders the em dash `—` with
`title="Conta removida"`; with an account it renders
`CashLensWeb.Formatters.account_label/1`, which renders `"#{bank} - #{name}"` and appends `" (Encerrada)"` for a closed account (`lib/cash_lens_web/formatters.ex:6-9`) — a hyphen separator, not a middle dot; a test asserting the label must use the real separator. `list_recent_runs/1` already
preloads `:account`, so the template performs no query and never touches an unloaded
association.

**3. The file column shows the basename first and the directory as a subtitle, with the
content-hash form decoded.** `file_path` is the denormalized path *key*, which today takes
three shapes: `"<account dir>/<file>"` relative to the monitored root, an absolute path (ad-hoc
import with no root), and — once CL-25 lands — `"<content_hash>/<basename>"`, whose 64-hex
directory is unreadable. Rendering rule, applied to `Path.dirname/1`:

- `"."` (no directory part) → no subtitle;
- a 64-character lowercase-hex segment → the subtitle `Arquivo solto · <first 8 chars>…`;
- anything else → the dirname verbatim, truncated with CSS, not by string slicing.

The basename is `Path.basename(file_path)` in monospace. The cell's `title` attribute always
carries the **full stored `file_path`**, unmodified, so nothing is lost. This rule is purely
presentational and depends on no CL-25 code, so the panel behaves correctly whether or not
CL-25 has landed.

**4. Limit: 20, no pagination.** The panel calls `CashLens.Imports.list_recent_runs(20)` with
the limit passed explicitly (matching the function's own default) and offers **no** "see more",
page or filter control — this is a recency panel, not a log browser. The header states the
bound in words: `Últimas 20 execuções`. Ordering is `list_recent_runs/1`'s own
(`ran_at desc, inserted_at desc`); the LiveView must not re-sort in the template.

**5. Empty state.** No runs → the table is replaced by a block with the stable id
`#history-empty` and the text `Nenhuma importação registrada ainda.`, plus a hint that the
history records executed imports only (previews write nothing). The panel itself, its header
and its id `#import-history` are always rendered, so tests can target them in every state.

**6. Refresh points.** One private `assign_history/1` is the only place `list_recent_runs/1` is
called, and it is invoked from `mount/3`, from CL-23's `"rescan"` handler, and at the end of
CL-24's successful `"confirm_import"` handler — so a confirmed import makes its row appear
without a page reload. No PubSub, no polling, no `Task`, consistent with CL-23 decision 8 and
CL-24 decision 9.

**7. Timestamps are rendered as stored.** `ran_at` is a UTC `DateTime`; it is formatted with
`Calendar.strftime(run.ran_at, "%d/%m/%Y %H:%M")` with **no** timezone conversion, identical to
how CL-23 renders `mtime` and `last_imported_at`. Introducing a local timezone here is out of
scope and would be inconsistent with the rest of the screen.

### Behavior

- `/imports` renders a section `#import-history` titled `Importações recentes` with the
  subtitle `Últimas 20 execuções`, below the file list (replacing CL-23's HTML comment).
- The table has the columns: `Data`, `Conta`, `Arquivo`, `Situação`, `Importadas`, `Ignoradas`.
  `Importadas` shows `imported_count`, `Ignoradas` shows `skipped_count`.
- Every `<tr>` carries `data-run-id={run.id}` and `data-run-status={run.status}`, so tests and
  future parts target rows by selector rather than by copy.
- Rows appear newest-first, at most 20 of them.
- A `"error"` row is listed alongside the others: red `Erro` badge, `0` in both count columns
  (the writer forces `0/0/0`), and its `error_message` rendered in full as a secondary line
  inside the Arquivo cell, marked `data-role="run-error"`. It is never hidden or filtered out.
- A `"warning"` row additionally renders `N linha(s) rejeitada(s)` under the badge, from
  `failed_count`, marked `data-role="run-failed"`.
- No control in the panel triggers a write; there are no buttons other than the ones CL-23 and
  CL-24 already own.

### Files touched

- `lib/cash_lens_web/live/import_live/index.ex` — replace the
  `<!-- CL-26: recent import history -->` comment with the panel markup; add private
  `assign_history/1`, call it from `mount/3`, `"rescan"` and the success branch of
  `"confirm_import"`; add the private view helpers `run_badge/1` (decision 1),
  `run_file_label/1` (decision 3) and `run_account_label/1` (decision 2).
- `test/cash_lens_web/live/import_live_test.exs` — a new
  `describe "recent import history"` block.

No other file changes. `lib/cash_lens/imports.ex`, `lib/cash_lens/parsers/ingestor.ex`, the
schema and the migration are all untouched.

### Test criteria

In `test/cash_lens_web/live/import_live_test.exs`, reusing CL-23's tmp-root fixtures and its
mandatory `last_batch_import_path` save/restore `setup`. Runs are inserted directly with
`CashLens.Imports.record_run/1` except where an end-to-end import is required.

1. **Columns and reading from `import_runs`**: a `"success"` run inserted with known
   `ran_at`, account, `file_path`, `imported_count: 7`, `skipped_count: 3` renders a row whose
   cells contain the formatted date, the account label, the basename, `7` and `3`.
2. **Badges**: three runs, one per status, render `data-run-status` of `success`, `warning` and
   `error` with the labels `Sucesso`, `Aviso` and `Erro` respectively.
3. **Ordering and limit**: 25 runs with strictly decreasing `ran_at` render exactly 20 rows
   (`Floki`/`LazyHTML` count on `#import-history tbody tr`), and the first row is the newest.
4. **Error rows**: a run with `status: "error"`, `error_message: "Could not read file: enoent"`
   and default counts renders the `Erro` badge, the message under
   `[data-role="run-error"]`, and `0` in both count columns.
5. **Nil account**: a run recorded with `account_id: nil` renders without crashing and its
   Conta cell contains `—`.
6. **Content-hash path**: a run whose `file_path` is
   `"<64 hex chars>/nubank.csv"` renders `nubank.csv` and `Arquivo solto`, and does **not**
   render the full 64-character hash as visible text.
7. **Integration — a confirmed import produces a row**: with a file in the monitored tmp root,
   drive CL-24's flow on the LiveView (`"inspect"` then `"confirm_import"`); after the confirm,
   `#import-history` contains a new row whose `Importadas` cell equals the number of
   transactions the confirm flashed, without navigating away or remounting. (Should CL-24's
   confirm handler not be present in the tree at implementation time, the same assertion is
   made by calling `CashLens.Parsers.Ingestor.import_file/3` with the screen's root and then
   firing `"rescan"` — the refresh path of decision 6 is what is under test either way.)
8. **Empty state**: with no `import_runs` rows, `#history-empty` is rendered and
   `#import-history tbody tr` matches nothing.
9. `mix test test/cash_lens_web/live/import_live_test.exs` passes, `mix format
   --check-formatted` is clean, and `mix credo` reports no findings in
   `lib/cash_lens_web/live/import_live/index.ex` or the test file that were not already present
   before this task. The repo carries pre-existing credo findings in untouched files; a
   project-wide `--strict` gate is explicitly **not** a criterion.

Mockup: ![Mockup CL-26](CL-26-mock.html) — `docs/tasks/CL-26-mock.html`, extending the visual
language of `CL-23-mock.html` and `CL-24-mock.html`.

## Expected Results

- [ ] A `#import-history` table on `/imports` lists one row per `import_runs` record with the
      columns Data, Conta, Arquivo, Situação, Importadas (`imported_count`) and Ignoradas
      (`skipped_count`), read through `CashLens.Imports.list_recent_runs/1`
- [ ] Each row carries `data-run-status` and a badge matching the stored status exactly:
      `success` → `Sucesso` (green), `warning` → `Aviso` (amber), `error` → `Erro` (red); any
      other value renders a grey badge with the raw value instead of crashing
- [ ] Rows render newest-first in `list_recent_runs/1`'s order and are capped at 20; 25 stored
      runs render exactly 20 rows and no pagination control exists
- [ ] Runs with `status: "error"` are listed alongside the others with the `Erro` badge, their
      `error_message` visible under `[data-role="run-error"]`, and `0` in both count columns
- [ ] A run whose `account` is `nil` renders an em dash in the Conta cell without raising
- [ ] A run whose `file_path` is `"<64-hex>/<basename>"` renders the basename plus an
      `Arquivo solto` marker, never the bare 64-character hash as visible text
- [ ] With no `import_runs` rows, `#history-empty` is rendered and the history table body is
      empty
- [ ] After an import confirmed through the screen, the panel shows a new row whose Importadas
      count equals the number of transactions actually imported, without a page reload
      (covered by an integration test)
- [ ] `test/cash_lens_web/live/import_live_test.exs` passes under `mix test`
- [ ] `mix format --check-formatted` is clean and `mix credo` reports no NEW findings in the
      files this task touches (pre-existing findings elsewhere are out of scope)

## Out of Scope

- Removing the legacy import modals in `TransactionLive.Index` (CL-27).
- The drag-and-drop dropzone (CL-25); this panel must work with or without it.
- Filtering, searching, pagination or per-run detail drill-down in the history.
- Any change to `CashLens.Imports`, the `import_runs` schema/migration, or `Ingestor`.
