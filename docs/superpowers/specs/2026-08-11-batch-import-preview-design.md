# Batch import preview confirmation design

## Problem

The "Importar em Lote" modal (`CashLensWeb.TransactionLive.BatchImportModalComponent`)
runs a real, writing import as soon as the user submits a folder path (after
an account-existence preflight check) — there's no way to see how many
transactions would actually be imported before it happens.

## Goal

Add a preview step between "accounts are resolved" and "the real import
runs": compute, per account, how many transactions would be newly imported
vs. already exist vs. fail — with zero database writes — show it to the
user, and only run the real (writing) import after they confirm.

## Non-goals

- No transaction list preview (which rows, specifically) — counts only, per
  account, matching the density the existing "Importação Concluída" result
  screen already uses.
- No change to the account-creation confirmation step that already exists
  (`:needs_confirmation` phase) — it still creates missing accounts for real
  before the preview runs, unchanged.
- No attempt to avoid double-processing (parsing files twice — once to
  preview, once for real). Accepted tradeoff, confirmed with the user: this
  app is local, personal, occasional-use, and the safety/simplicity of two
  separate passes outweighs optimizing for speed.
- No open-spanning database transaction wrapping the confirmation click.
  Rejected explicitly during design: holding a checked-out Ecto connection
  across an indefinite user-interaction gap doesn't fit LiveView's
  one-event-per-message model without deep, fragile restructuring, and risks
  the connection pool. The preview approach below achieves the same UX
  (see the count before it happens) safely.

## Mechanism: how the preview computes counts with zero writes

`CashLens.Parsers.Ingestor.import_file/3` already accepts an `opts` keyword
list (currently only `:notify_fn`). It gains `:dry_run`.

- `process_imported_content/5` (currently `/4`, gains a `dry_run` argument)
  branches after parsing: real mode calls the existing
  `maybe_create_statement/4` (writes a `credit_card_statements` row) then
  `finalize_import/3` (writes transactions, `Logger`s balance rebuilds,
  etc.) — both **unchanged**. Dry-run mode skips statement creation
  entirely and calls a new `preview_import/2` instead.
- `preview_import(transactions_data, account_id)` reuses the *existing*
  `prepare_entries/3` unchanged (the same function that computes each
  transaction's real dedup fingerprint) — passing `nil` for `statement_id`
  (fingerprints never depend on it; only non-credit-card imports already
  pass `nil` today, so this is an existing, proven path). It then queries
  which of those fingerprints already exist in the `transactions` table
  (`WHERE fingerprint IN (...)`) — the exact same check the real import's
  `on_conflict: :nothing` / `conflict_target: :fingerprint` insert would
  perform — and returns the identical `%{imported:, skipped:, failed:}`
  shape `finalize_import/3` returns today, so every caller up the stack
  (`DirectoryImporter.do_import/7`'s per-file summary-accumulation loop)
  needs **zero changes** — it already just sums whatever shape
  `Ingestor.import_file/3` returns, real or preview.
- `DirectoryImporter.run/2` gains the same `:dry_run` option, threaded
  through to every `Ingestor.import_file/3` call. When `dry_run: true`, it
  also skips `CashLens.Installments.scan_and_apply_all()` (a real,
  installment-linking write) — the existing `:skip_installments` option's
  code path already has the right shape to extend with this condition. As
  today, `:create_missing` is never combined with a preview call — by the
  time the UI ever requests a preview, the account-existence step has
  already resolved (accounts already existed, or were just created for
  real via the pre-existing confirmation flow) — so `preview_import/2`
  itself never touches account creation.

Nothing about `finalize_import/3`, `process_entries/4`, or
`batch_insert_transactions/1` changes — the real import path is byte-for-byte
what it is today.

## UI flow

Both existing entry points into a real import — (a) preflight passes
immediately (all accounts already exist), and (b) the user just confirmed
creating missing accounts — now route through the preview step instead of
going straight to `:importing`:

```
path submitted
      │
      ▼
 preflight/1
      │
      ├─ {:error, _} ──────────────────────────► :done (error view, unchanged)
      │
      ├─ {:needs_confirmation, missing} ──► :confirming (unchanged) ──confirm──┐
      │                                                                        │
      └─ :ok ──────────────────────────────────────────────────────────────┐  │
                                                                             ▼  ▼
                                                                        :previewing
                                                                    (dry-run, progress
                                                                     bar reused from
                                                                     today's :importing
                                                                     view, relabeled)
                                                                             │
                                                                             ▼
                                                                    :preview_confirm
                                                              (per-account counts,
                                                               "Confirmar Importação"
                                                               / "Cancelar")
                                                            confirm │       │ cancel
                                                                    ▼       ▼
                                                              :importing   :idle
                                                             (real import,  (path
                                                              unchanged)    form)
```

- `:previewing` reuses the existing `progress_view/1` component (it already
  renders generically off `@batch_progress`'s account/file counters) with
  its heading changed to "Calculando pré-visualização..." when previewing
  vs. "Importando em Lote..." when doing the real import — a single new
  boolean in the progress assign (`preview?`) drives the heading text; no
  new progress-bar code.
- `:preview_confirm` is a new view, `preview_confirm_view/1`, structurally
  a trimmed copy of the existing `result_view/1`'s per-account list (icon +
  folder label + "N novas, M já existem" line — reusing `result.accounts`'
  existing `%{imported:, skipped:, failed:, folder_path:, ...}` shape, just
  relabeled "novas"/"já existem" instead of "importadas"/"já existiam") plus
  a confirm/cancel button pair instead of the result view's single "Fechar"
  button.
- The component's `start_batch_import/2` private helper (which spawns the
  background `Task`/inline call and wires `on_event` progress messages)
  gains a `preview?: boolean` parameter, included in the
  `{:batch_import_finished, result, preview?}` message so
  `handle_info`/the component's own finish-handling can branch: preview
  finishing sets phase `:preview_confirm`; a real import finishing keeps
  today's behavior (phase `:done`).
- New events: `"confirm_import"` (from `:preview_confirm`, starts the real
  import with the same path, `dry_run: false`) and reuse the existing
  `"cancel_confirmation"` event (already resets to idle) for the preview's
  "Cancelar" button too, rather than inventing a second cancel event with
  identical behavior.

## Testing

- `Ingestor.import_file/3` with `dry_run: true`: returns
  `{:ok, %{imported: n, skipped: n, failed: []}}` matching what a
  subsequent real call (same input) actually inserts; makes zero
  `transactions` or `credit_card_statements` rows (assert via `Repo.all`
  count unchanged before/after); running it twice in a row returns the same
  counts both times (proves it has no side effect that would change the
  second call's answer).
- `DirectoryImporter.run/2` with `dry_run: true`: same account-level
  summary shape as a real run against the same fixture directory; zero DB
  writes; does not call `Installments.scan_and_apply_all/0` (verify via a
  test double / call-count assertion, matching how `:skip_installments` is
  already tested).
- `BatchImportModalComponent`: submitting a path with all accounts already
  present goes to `:previewing` then `:preview_confirm` (not straight to
  `:importing`); the preview screen's per-account counts match a real
  import of the same fixture; clicking "Confirmar Importação" performs the
  real import and reaches `:done` with matching final counts; clicking
  "Cancelar" from `:preview_confirm` returns to the idle path form with no
  DB writes; the account-creation flow (`:confirming` →
  `confirm_create_accounts`) now also lands on `:preview_confirm` instead
  of jumping straight to `:importing`.
