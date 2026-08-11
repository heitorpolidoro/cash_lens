# Batch import: cached-commit (no reprocessing) design

## Problem

The preview feature shipped in
[2026-08-11-batch-import-preview-design.md](2026-08-11-batch-import-preview-design.md)
deliberately parses every file twice: once to preview, once for real. The
user tried it and doesn't want the wait — they'd rather cache what the
preview already computed and use it directly when they confirm, accepting
the staleness risk that design explicitly avoided.

## Goal

When the user confirms an import, use the exact data the preview already
parsed and prepared — no re-reading, no re-converting PDFs, no re-parsing —
so confirming is just the database write. Guard against the one real risk
this reintroduces (a file changing on disk between preview and confirm)
with a cheap modification-time check that cancels the whole write, with no
partial import, if anything changed.

## Non-goals

- No protection against an *account record* changing between preview and
  confirm (e.g. the user edits the account's bank/name in another tab). The
  user's explicit ask was about file staleness; this is a separate, much
  narrower edge case not worth guarding against here.
- No change to the preview screen's UI or content — same per-account
  counts, same layout. Only what happens after "Confirmar Importação" is
  clicked changes.
- No change to `finalize_import/3` (the single-file, non-cached real-import
  path used by `mix cash_lens.import` and any other direct caller) — it
  keeps re-reading and re-parsing, unchanged. This design only replaces
  what the *batch-import preview flow specifically* does when the user
  confirms — a single-file `Ingestor.import_file/3` call outside that flow
  behaves exactly as it does today.

## What gets cached, and where

During the (unchanged) dry-run preview pass, for each file inside each
account folder, `DirectoryImporter` already computes everything a real
import would need — it just currently throws away everything except the
count. This design keeps the rest:

```
%{
  file_path: file_path,
  mtime: <captured via File.stat!/1 at preview time>,
  account: account,              # the resolved Account struct
  transactions_data: [...],      # parsed rows, already future-date-filtered
  entries: [...],                # prepared Transaction attr maps (fingerprint,
                                  # everything `process_entries/4` needs to insert)
  failed: [...],                 # parse/prepare failures for this file
  statement_meta: meta | nil     # due_date/total_a_pagar/competencia, only for
                                  # credit-card accounts; nil otherwise
}
```

This is attached to each account's entry in `DirectoryImporter.Result`
(alongside the existing `imported`/`skipped`/`failed`/`folder_path` fields),
so the whole cache travels with the `Result` the preview screen already
holds in the LiveComponent's assigns — no new storage layer, no database
table, purely an in-memory structure for the lifetime of one preview → confirm
round trip.

**One nuance:** `entries`' `import_batch_id` field is `nil` when cached,
because no statement row exists yet at preview time (dry runs create
nothing). At commit time, a *fresh* `credit_card_statements` row is created
(same as today's real import always creates one per file for a credit-card
account) and every cached entry for that file gets `import_batch_id` patched
to the new statement's id before insert — the cached `entries` are reused for
everything except this one field, which can only be known once a statement
actually exists.

## The staleness check

Before writing anything, walk every cached file across every account and
compare `File.stat!(file_path).mtime` against the `mtime` captured during
preview. If **any** file's mtime differs:

- **No writes happen at all** — not just for the changed file, for the
  entire confirm operation. Partial imports (some accounts written, others
  not, based on which files happened to still match) would leave the user
  with a confusing, hard-to-reason-about intermediate state.
- The UI shows an error naming which file(s) changed, and tells the user to
  run "Importar em Lote" again from the start to get a fresh preview.

If every file's mtime still matches, the commit proceeds using the cached
data — no file is re-read.

## Committing from cache

A new function alongside `Ingestor`'s existing `finalize_import/3` takes one
cached file's package and does only the write-side steps `finalize_import/3`
already does, minus the parts that require re-reading/re-parsing:

1. If the account is a credit-card account, create a new statement row using
   the cached `statement_meta` (unchanged shape/logic from today's
   `maybe_create_statement/4` — just sourced from the cached `meta` instead
   of a fresh `statement_meta(content, file_path)` call).
2. Patch `import_batch_id` on the cached `entries` to that new statement's id
   (or leave `nil` for non-credit-card accounts, matching today).
3. Call the *existing, unchanged* `process_entries/4` (batch insert with
   `on_conflict: :nothing`, transfer-rule application, transfer matching,
   credit-card payment auto-linking, affected-account collection) — this
   function doesn't change at all; it already accepts prepared entries and
   doesn't care whether they were just computed or came from a cache.
4. Rebuild balances for the affected accounts — same as today.

`DirectoryImporter` gains the equivalent top-level entry point: given a
cached `Result` (from a completed preview), run the staleness check across
every file first; if clean, commit every account's cached files the same
way `do_import/8`'s real-import branch does today, then run the installment
scan once at the end — matching the real import's existing overall shape,
just skipping straight to the write step per file since parsing already
happened.

## UI change

"Confirmar Importação" currently calls `start_batch_import(path, [dry_run:
false], false)`, which re-walks the directory and re-parses everything. It
now instead calls the new cached-commit entry point, passing the preview's
already-held `Result` — no `path` re-walk, no file re-reads except the cheap
mtime stats.

If the staleness check fails, the modal shows a new error state (not a
crash, not a silent partial import) naming the changed file(s), with a
button back to the empty path form so the user can start over.

## Testing

- A cached-commit run on unchanged files produces the exact same DB state a
  fresh (non-cached) real import of the same files would — reuse the
  existing "preview count matches subsequent real import" test pattern, but
  now asserting the *cached* commit matches too.
- Modifying a file's content (and therefore its mtime) between preview and
  confirm causes the whole confirm to be rejected with zero writes — assert
  no transactions, no statements, from any account in that batch, not just
  the changed file's account.
- A credit-card account's cached entries get `import_batch_id` correctly
  patched to the newly-created statement's id at commit time (not left
  `nil`, not pointing at a stale/nonexistent id).
- Two files with overlapping transactions in one account folder (the
  scenario the prior feature's final review caught as a real bug) still
  produce the correct, non-double-counted result when committed from cache.
- `process_entries/4` itself needs no new tests — it's unchanged; existing
  coverage still applies.
