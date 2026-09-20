# CL-24 — Pre-write Inspection drawer on `/imports`: preview, then confirm

Part 4 of 7 of the CL-8 decomposition, on top of CL-23 (the `/imports` screen shell) and CL-21
(`CashLens.Imports`, `imported_files`, `import_runs`). This task fills the insertion point
CL-23 left in the row action cell (`<!-- CL-24: pre-write inspection action per row -->`) with
an **Inspecionar** action that opens a drawer showing exactly what a real import of that one
file would do — and only writes anything when the operator confirms.

## Scope

Covers:

- Extending the Ingestor's **existing** dry-run path so it returns the preview rows alongside
  the counts it already computes, from the same single pass (no second parse, no second
  fingerprint computation, no parallel implementation).
- An `Inspecionar` button on every file row of `CashLensWeb.ImportLive.Index`.
- A pre-write inspection drawer rendered with the existing `<.modal>` core component: new
  count, skipped-duplicate count, a tabular preview of the transactions, and a confirm button.
- The confirm path: re-verify the file on disk, run the real import, report the persisted
  counts, re-scan the list.
- One small addition to `CashLens.Imports` (`account_for_entry/1`) so the web layer does not
  query `CashLens.Accounts` directly.

Does **not** cover: the drag-and-drop dropzone (CL-25), the recent-import history panel
(CL-26), batch/folder-wide inspection, any change to the parsers, to `Imports.scan/1`, to
`DirectoryImporter`, to the dedup/fingerprint rules, or to the legacy import modals in
`TransactionLive.Index`. Note that a confirmed import here naturally writes an `import_run`
row, which is what CL-26 will later display; CL-24 does not render that history.

## Approach

### Decisions (binding — no implementer discretion)

**1. The return shape is extended, not wrapped, and only on the dry-run side.**
`Ingestor.preview_import/3` (the private function already reached by both
`import_file/3` with `dry_run: true` and `preview_file/3`) returns
`{{:ok, %{imported:, skipped:, failed:, preview: [row]}}, claimed}` — the existing three keys
keep their exact current meaning and a fourth key is added. `finalize_import/3` (the real
import) is **not** touched and keeps returning the three-key map.

This is safe for every existing caller, each of which was checked:

- `Ingestor.summarize_results/1` (`ingestor.ex:128`) — partial patterns plus `Map.get/3`;
  and it only ever sees real-import results anyway.
- `DirectoryImporter.do_import/8` (`directory_importer.ex:244`) — rebuilds its accumulator as
  an explicit three-key map, so `:preview` is deliberately dropped at the batch level. Folder-
  wide preview rows are out of scope; the batch summary and `BatchImportModalComponent`
  therefore stay byte-identical.
- `TransactionLive.ImportModalComponent` (`import_modal_component.ex:108`) — real import only.
- Every existing assertion in `test/cash_lens/parsers/ingestor_test.exs` (including
  `:345`, `:359`, `:372`) and `test/cash_lens/imports_test.exs` (`:317` describe block) uses
  partial map patterns or `summary.imported`, so an added key breaks none of them.

**2. The rows come from the pass that already computes the counts.** The rows are emitted from
inside `preview_import/3`'s existing `Enum.reduce` over `entries` — the very reduction that
classifies each entry as new or already-present. The implementation must not add a second call
to `parse/2`, `prepare_entries/3` or `existing_fingerprints/1`. Each row is derived from the
prepared insert entry it classifies:

```
%{date:, time:, description:, amount:, category_id:, fingerprint:, status: :new | :duplicate}
```

`:time` and `:category_id` are read with `Map.get/2` — the entry is `changeset.changes` and
they may legitimately be absent. Rows keep file order and include **both** classifications, so
the drawer can show what is about to be skipped and why. Rows that failed preparation never
became entries and stay in `failed`; they are not preview rows.

**3. Preview size: the Ingestor returns everything, the LiveView truncates the rendering.**
`entries` is already fully materialized in memory before this change, so returning one row per
entry adds no new cost or risk, and truncating inside the Ingestor would make the same function
mean different things to different callers. The LiveView renders at most **200** rows
(`@preview_limit`) and, when the list is longer, a footer line `mostrando 200 de N linhas`,
where **N is the full preview length — new plus duplicate rows — not the new count**.
The two counters in the drawer header are always `summary.imported` and `summary.skipped` as
returned by the Ingestor — **full-file counts, never derived from the truncated list**. A
truncated count would be a lie and is explicitly forbidden.

**4. The no-write guarantee, and how the code enforces it.** Every DB write reachable from
`import_file/3` was enumerated and each is already behind an explicit guard:

- `ingestor.ex:98` — `record_import` on the unreadable-file branch: guarded by
  `if dry_run == false`.
- `ingestor.ex:160` — `record_import` on the parse-error branch: guarded by
  `if dry_run == false` (this branch sits above the `if dry_run`, hence its own guard).
- `ingestor.ex:171–175` — `maybe_create_statement/4` (credit-card statement insert),
  `finalize_import/3` and `record_import/5`: all inside the `else` of the `if dry_run` at
  `:167`, therefore unreachable in a dry run.
- Transitively inside `finalize_import/3` only: `batch_insert_transactions/1`,
  `TransferRuleApplier.apply_rules/1`, `CreditCards.absorb_pending/1`,
  `CreditCards.Matcher.auto_link/2` and `Accounting.rebuild_account_balances/1` (which is also
  the only thing on this path that can enqueue an Oban job).
- `preview_import/3` itself touches the database exactly once, through
  `existing_fingerprints/1`, which is a `Repo.all` SELECT.

**Finding: there is no unguarded write on the dry-run path today.** This task's only duty is
not to introduce one: the preview rows are built inside the read-only `preview_import/3`, and
the LiveView's inspection path must never call `Imports.record_run/1`,
`Imports.upsert_imported_file/1`, or `import_file/3` without `dry_run: true`. "No write" here
covers `transactions`, `imported_files`, `import_runs` and `credit_card_statements`, and the
test asserts all four counts are unchanged.

**5. Confirming re-verifies the file, and refuses stale data.** When the drawer opens, the
LiveView stores the `content_hash` of the bytes it inspected (it already has it —
`Imports.scan/1` returns `entry.content_hash`). On `"confirm_import"`:

- the file is re-read and `Imports.content_hash/1` recomputed;
- **hash differs** → nothing is imported; an `:error` flash `O arquivo mudou no disco.
  Inspecione novamente.` is shown, and the drawer immediately re-runs the dry run so the
  operator sees the new preview. Chosen over the alternatives because criterion "persisted
  counts match the preview" is only meaningful if the confirmed bytes are the inspected bytes;
  silently importing changed data would break it invisibly, and silently re-running would make
  the operator confirm something they never saw;
- **file unreadable/gone** → `import_file/3` returns `{:error, _}` and, by design
  (`ingestor.ex:98`), records an **error** `import_run`. That is correct: this is the confirm
  path, a genuinely attempted import, not the inspection path. Flash the error, close nothing;
- **hash equal** → `Ingestor.import_file(account, entry.absolute_path, import_root: root)` runs.
  Note the check narrows the window but is **not atomic**: `import_file/3` performs its own
  `File.read/1`, so a write landing between the confirm-time re-read and that read is still
  possible. This is accepted — the monitored folder is a local, single-operator directory —
  and is stated here so the hash check is not mistaken for a guarantee.
  Since the input bytes and the fingerprint logic are identical to the dry run, the returned
  `imported`/`skipped` equal the previewed counts. They are shown in an `:info` flash
  (`N transações importadas, M duplicadas ignoradas.`), the drawer closes, and the list is
  re-scanned through CL-23's `assign_scan/2` so the row flips to `Sincronizado`.

One residual race is accepted and not guarded: another process inserting matching transactions
between inspection and confirmation would shift `skipped`. CashLens is a single-user local app
with no concurrent importer; the real import's own counts remain authoritative and are what is
flashed and recorded.

**6. Account resolution stays in the context.** `scan/1` entries carry `bank`/`account`
strings, not an account struct. New `CashLens.Imports.account_for_entry/1` returns
`{:ok, account}` / `{:error, :not_found}` / `{:error, :ambiguous}` via
`Accounts.find_accounts_by_bank_and_name/2` — the same resolution `DirectoryImporter` performs,
so the drawer previews with exactly the account a batch import would use, and
`CashLens.Accounts` is not referenced from `lib/cash_lens_web/live/import_live/`.
Unresolvable → the drawer opens on an `#inspect-error` block (`Conta não encontrada para esta
pasta.` / `... está ambígua ...`) with **no** confirm button.

**7. Every row is inspectable, including `Sincronizado` ones** — inspecting a synced file
previews `0 novas / N duplicadas`, which is precisely the evidence that it is synced.

**8. The path from the client is never used as a filesystem path.** `phx-value-path` is looked
up against `@entries` (the last scan) by `:path`; no match → the event is a no-op. The
absolute path used for reading and importing is always `entry.absolute_path` from the scan.

**9. Synchronous, like CL-23.** No `Task`, no PubSub. A PDF dry run pays the converter cost
inline; acceptable for a local single-user screen, and consistent with CL-23 decision 8.

### Behavior

- Each file row of `/imports` renders a button `Inspecionar` carrying
  `phx-click="inspect" phx-value-path={entry.path}` and `data-role="inspect"`.
- Clicking it opens `#inspect-drawer` (a `<.modal>` with `show`, `on_cancel` pushing
  `"close_inspect"`), containing: the file path and `bank · conta` in the header; two counters
  with stable ids `#preview-new-count` and `#preview-skipped-count`; a table of preview rows
  (date, description, amount, per-row badge `Nova` / `Duplicada`), each `<tr>` carrying
  `data-preview-row` and `data-row-status`; a `Cancelar` button; and a `Confirmar importação`
  button (`phx-click="confirm_import"`).
- When `failed` is non-empty, a warning block lists the rejected rows; it does not block
  confirmation (the real import will reject them the same way).
- When `imported == 0`, the confirm button is still enabled (a zero-row import is a legitimate
  way to mark a file as synced), but the drawer shows `Nada novo para importar.`.
- Closing the drawer (`Cancelar`, backdrop, Esc) writes nothing and leaves the list untouched.

### Files touched

- `lib/cash_lens/parsers/ingestor.ex` — `preview_import/3` emits the `:preview` rows from its
  existing reduce; the `@doc` of `import_file/3` and `preview_file/3` documents the new key and
  states that `finalize_import/3` does not carry it.
- `lib/cash_lens/imports.ex` — add `account_for_entry/1`; nothing else changes.
- `lib/cash_lens_web/live/import_live/index.ex` — the row action button replacing CL-23's
  HTML comment, `handle_event/3` for `"inspect"`, `"close_inspect"` and `"confirm_import"`, the
  `@inspect` assign (`nil` or `%{entry:, account:, summary:, hash:}`), and the drawer markup.
- `test/cash_lens/parsers/ingestor_test.exs` — preview-key coverage on the Ingestor side.
- `test/cash_lens_web/live/import_live_test.exs` — new `describe "pre-write inspection"`.

### Test criteria

In `test/cash_lens/parsers/ingestor_test.exs` (existing `dry_run` describe block):

- `import_file(account, @bb_sample, dry_run: true)` returns a summary whose `preview` has
  `length == imported + skipped`, every row carrying `:date`, `:description`, `:amount` and a
  `:status` in `[:new, :duplicate]`; on a virgin DB all rows are `:new`.
- After a real import of the same file, a second dry run returns every row as `:duplicate`,
  `imported: 0`, and the DB row counts are unchanged.
- The real `import_file/3` result does **not** contain a `:preview` key.

In `test/cash_lens_web/live/import_live_test.exs` (reusing CL-23's tmp-root fixtures and its
mandatory `last_batch_import_path` settings save/restore `setup`):

1. Clicking `[data-role="inspect"]` for a file renders `#inspect-drawer`, and
   `#preview-new-count` shows the same number the Ingestor's dry run reports for that file.
2. **No-write guarantee**: counts of `Transaction`, `ImportedFile`, `ImportRun` and
   `CreditCards.Statement` captured before opening the drawer are identical after it is open
   and rendered (and still identical after `"close_inspect"`).
3. Confirming imports for real: `Transaction` count grows by exactly the previewed new count,
   exactly one `ImportRun` row exists with `imported_count` equal to the previewed number, an
   `ImportedFile` row exists for the file, and the re-rendered row shows
   `data-status="synced"`.
4. Inspecting an already-imported file shows `#preview-new-count` = 0 and every preview row as
   duplicate; confirming it adds no `Transaction` row.
5. A file rewritten between opening the drawer and confirming: the confirm is refused, the
   error flash is rendered, and the `Transaction` count is unchanged.
6. A file whose `.account` names an account that does not exist renders `#inspect-error` and no
   confirm button.
7. Truncation: an account folder file with 205 parseable rows renders exactly 200
   `[data-preview-row]` elements while `#preview-new-count` shows 205.
- `mix test test/cash_lens_web/live/import_live_test.exs test/cash_lens/parsers/ingestor_test.exs
  test/cash_lens/imports_test.exs test/cash_lens/parsers/directory_importer_test.exs` passes.

## Expected Results

- [ ] `Ingestor`'s existing dry-run path (`import_file/3` with `dry_run: true` and
      `preview_file/3`) returns `%{imported:, skipped:, failed:, preview: [row]}`, with the
      rows produced inside the same `preview_import/3` reduce that computes the counts — no
      second parse, no second `prepare_entries/3`, no second `existing_fingerprints/1`
- [ ] The real import path (`finalize_import/3`) still returns the unchanged three-key
      `%{imported:, skipped:, failed:}`, and `DirectoryImporter`, `BatchImportModalComponent`
      and every existing Ingestor/Imports/DirectoryImporter test pass untouched
- [ ] Each file row on `/imports` renders an `Inspecionar` button that opens `#inspect-drawer`
- [ ] The drawer renders `#preview-new-count`, `#preview-skipped-count` and a table of
      `[data-preview-row]` rows showing date, description and amount, each marked new or
      duplicate
- [ ] While the drawer is open, the row counts of `transactions`, `imported_files`,
      `import_runs` and `credit_card_statements` are unchanged from before it was opened, and
      a test asserts exactly that
- [ ] A `Confirmar importação` button inside the drawer runs the real import; afterwards the
      new `transactions` rows **in the imported file's own account** and the
      `import_runs.imported_count` equal the number shown in `#preview-new-count`, and the
      file row re-renders as `data-status="synced"`. The equality is scoped to that account
      on purpose: `TransferRuleApplier.apply_rules/1` may insert mirror rows in *other*
      accounts as a side effect of a confirmed import, so a repo-wide `transactions` count
      is not expected to match the previewed number.
- [ ] If the file's content hash changed between opening the drawer and confirming, the import
      is refused, an error flash is shown, nothing is written, and the preview is refreshed
- [ ] A file whose `.account` resolves to no (or an ambiguous) account opens the drawer on
      `#inspect-error` with no confirm button
- [ ] A preview longer than 200 rows renders exactly 200 rows plus a `mostrando 200 de N`
      note, while the two counters still show the full-file numbers
- [ ] `test/cash_lens_web/live/import_live_test.exs` covers opening the inspection, the
      no-write guarantee and confirming, and passes under `mix test`
- [ ] `mix format --check-formatted` is clean and `mix credo` reports no NEW findings in the
      files this task touches (pre-existing findings elsewhere in the repo are out of scope)
- [ ] No dropzone (CL-25) and no import-history panel (CL-26) is implemented

## Out of Scope

- CL-25 dropzone, CL-26 recent-import history, folder-wide (batch) inspection.
- Any change to the parsers, `Imports.scan/1`, `DirectoryImporter`, the dedup/fingerprint
  rules, or the legacy `TransactionLive` import modals.

Interactive mockup: `docs/tasks/CL-24-mock.html`
