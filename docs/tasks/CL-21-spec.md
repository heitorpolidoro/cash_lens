# CL-21 — Create the `CashLens.Imports` context with file tracking and run history

Part 1 of 7 of the CL-8 decomposition. Backend only: two migrations, one context, and the
hook that makes the existing file importer record what it did. No UI, no route, no LiveView.

## Scope

Covers:

- A new `imported_files` table tracking, per statement file, the content hash, filesystem
  mtime and the moment it was last imported.
- A new `import_runs` table: one row per executed (non-dry-run) file import, with date,
  account, file, status and the imported/skipped counts.
- A new context `CashLens.Imports` exposing `scan/1` (disk state vs. recorded state) plus the
  small read/write API the later CL-8 parts consume.
- Hooking the real (non-dry-run) path of `CashLens.Parsers.Ingestor.import_file/3` so it
  records both tables, plus the plumbing in `DirectoryImporter` that makes `scan/1` and the
  recorded path agree: `run/2` passes its monitored root down as `import_root:`, and its
  recursive file walk is exposed for reuse.

Does **not** cover: any change to what `run/2` imports or reports, the `/imports` LiveView, the monitored-folder setting UI, the dropzone,
the pre-write inspection modal, the history table rendering, any change to parsers, and any
change to the dedup/fingerprint rules. The Pluggy sync path is not instrumented.

## Approach

### Decisions (binding — no implementer discretion)

1. **`content_hash`** is `:crypto.hash(:sha256, raw_bytes) |> Base.encode16(case: :lower)` over
   the **whole file as read from disk** (`File.read/1`, before any UTF-8 normalization or PDF
   text extraction), stored as a 64-char lowercase hex string.
   **`mtime`** is read with `File.stat(path, time: :posix)` and stored as
   `DateTime.from_unix!(stat.mtime) |> DateTime.truncate(:second)` in a `:utc_datetime`
   column. POSIX mtime is already UTC; no local timezone is ever consulted, on write or on
   compare.
2. **`scan/1`** takes the monitored root directory (a binary path) and returns
   `{:ok, entries}`, or `{:error, reason}` when the path is not a directory. Each entry is a
   map with exactly these keys:
   `%{path: relative_path, absolute_path: abs, account_dir: rel_dir, bank: binary, account: binary, status: :new | :updated | :synced, content_hash: hex, mtime: DateTime.t(), last_imported_at: DateTime.t() | nil}`.
   Entries are sorted by `path`.
   - Only files **under a directory tree marked by a `.account` file** are returned. The
     enumeration is not re-implemented: `scan/1` calls the existing recursive
     `DirectoryImporter.partition_files/2` (made public, `@doc false`) with the account's
     `Ingestor.expected_extensions(parser_type)` and keeps only the `matching` half. Files
     whose extension does not match the account's parser (the `mismatched` half) are therefore
     **deliberately excluded** from the result: `run/2` never imports them, so listing them
     would show rows stuck at `:new` forever. A folder with no `.account` marker anywhere above
     it contributes nothing to the result and raises no error (the existing traversal already
     warns about those during import; `scan/1` stays silent).
   - `bank`/`account` come from `AccountFile.read/1` of the owning account dir; when that file
     is unparseable the whole subtree is skipped.
   - An **unreadable file** (either `File.read/1` or `File.stat/2` fails — e.g. a dangling
     symlink or a permission error) is omitted from the result and logged at `warn`. `scan/1`
     never returns a fourth status.
   - A path recorded in `imported_files` that **no longer exists on disk** never appears in the
     output (the scan is driven by the disk walk). Its row is deliberately kept, not deleted:
     it is the import history of a file that may come back from the Drive mount.
3. **`imported_files.path` is relative to the monitored root**, because the root is a Google
   Drive mount whose absolute path contains spaces and the user's email and can move or be
   remounted; an absolute-path unique index would turn a remount into a full re-import.
   The root is resolved once, by a public `CashLens.Imports.import_root(opts)`:
   `Keyword.get(opts, :import_root)` when it is a non-blank binary; otherwise
   `Settings.get("last_batch_import_path", "")` when non-blank; otherwise `nil`.
   The key is computed by a single public helper `CashLens.Imports.relative_path(abs_path, root)`:
   - `root` is a non-blank binary and the file is under it →
     `Path.relative_to(Path.expand(abs_path), Path.expand(root))` (a root-relative path);
   - `root` is `nil`/blank, **or** the file is not under the root → `Path.expand(abs_path)`
     (the absolute path). `Path.expand("")` is never used as a root; a blank root is
     normalized to `nil` first, so the cwd can never become an accidental root.

   `DirectoryImporter.run/2` passes its own `path` as `import_root:` on every
   `Ingestor.import_file/3` call it makes, so the production batch path always resolves a root.
   For the remaining callers (ad-hoc single-file imports) the root may be `nil` and the row is
   then keyed absolutely. To make that impossible to mismatch silently, **`scan/1` looks a file
   up under both keys**: it computes, for every discovered file, its root-relative key and its
   expanded absolute key, and preloads the rows with one query
   (`Imports.map_by_paths(keys)`, `where: path in ^keys`), preferring the root-relative row when
   both exist. A file recorded absolutely before the setting was configured is therefore still
   recognised as `:synced`/`:updated`, not re-listed as `:new`. The unique index is on `path`
   alone; a file that ends up with both an absolute and a relative row keeps both (the absolute
   one is an accepted legacy record, never deleted).
4. **`import_runs.status`** is a string, exactly one of:
   - `"success"` — the file was parsed and finalized with no failed rows;
   - `"warning"` — parsed and finalized, but `finalize_import/3` reported a non-empty `failed`
     list (rows that could not be prepared);
   - `"error"` — the file could not be imported at all (unreadable file, or the parser returned
     `{:error, reason}`); counts are `0`/`0` and `error_message` holds the reason.
5. **A re-import of an unchanged file still writes an `import_run`** (typically
   `imported_count: 0`, `skipped_count: n`) — the history records executions, not deltas. The
   `imported_files` row is always upserted with the values **freshly measured from disk** at
   that moment: `on_conflict` replaces `content_hash`, `mtime`, `last_imported_at` and
   `updated_at`. For an unchanged file the first two are byte-identical to what was stored, so
   the visible effect is only a refreshed `last_imported_at`; for a changed file they are
   updated. There is no "leave the old hash" case. An `imported_files` row is written/updated
   only when the import actually reached finalization (status `"success"` or `"warning"`),
   never on `"error"`.

`skipped_count` carries exactly the meaning `finalize_import/3` already gives `skipped`:
`length(entries) - inserted_count`, i.e. prepared rows the `fingerprint` unique index (or an
in-batch duplicate) rejected. No new notion of "duplicate" is introduced.

### Behavior

- `Imports.scan(root)` classifies each discovered file against its `imported_files` row:
  no row → `:new`; row whose `content_hash` **or** `mtime` differs from disk → `:updated`;
  row where both match → `:synced`.
- **Recording call sites in `lib/cash_lens/parsers/ingestor.ex` (exact, no implementer
  discretion).** A single new private helper (name at the implementer's discretion) is
  called from exactly three points, and from nowhere else:
  1. **`"error"` — unreadable file:** the `{:error, reason}` clause of `File.read/1` inside
     `import_file/3` (currently lines 95–96). `dry_run` is already bound at line 89, so this
     call is guarded by `dry_run == false`. Counts `0`/`0`, `error_message` = the reason.
  2. **`"error"` — parser failure:** the `{:error, reason}` clause of `case parse(...)` inside
     `process_imported_content/5` (currently lines 152–155). **This branch is shared with the
     dry run** — it sits above the `if dry_run` at line 161 — so the call here carries an
     explicit `dry_run == false` guard. Counts `0`/`0`, `error_message` = the reason.
  3. **`"success"` / `"warning"`:** the `else` branch of `if dry_run` (currently lines 164–169),
     on the `{:ok, summary}` returned by `finalize_import/3`. `"warning"` when
     `summary.failed != []`, `"success"` otherwise; `imported_count`/`skipped_count` from the
     summary, `failed_count = length(summary.failed)`.

  `preview_file/3` (lines 267–283) has its own read/parse and is never instrumented. No other
  line of `ingestor.ex` changes, so the real and preview paths keep sharing
  `prepare_entries/3` / `reject_future_dated/1` and cannot diverge.
- The helper hashes the **raw file bytes** as returned by `File.read/1` in `import_file/3`
  (line 91), **not** the `prepare_content/3` output — `process_imported_content/5` rebinds
  `content` at line 148, so the raw binary must be captured before that rebinding and passed
  to the helper. `mtime` comes from `File.stat(file_path, time: :posix)`; when the stat fails
  the row is recorded with `mtime: nil` rather than raising.
- The root used to key the path is `Imports.import_root(opts)` (decision 3), resolved inside
  the helper from the same `opts` `import_file/3` received.
- Recording never fails an import: the write is wrapped so a DB error is logged and the
  original `{:ok, summary}` / `{:error, reason}` return value of `import_file/3` is preserved
  byte-for-byte. Existing callers (`DirectoryImporter`, the mix task, the LiveView modals) see
  no signature or return-shape change.

### Files touched

- `priv/repo/migrations/<ts>_create_imported_files.exs` — `imported_files`: `id` binary_id,
  `path` string not null, `content_hash` string, `mtime` utc_datetime,
  `last_imported_at` utc_datetime, timestamps; unique index on `path`.
- `priv/repo/migrations/<ts>_create_import_runs.exs` — `import_runs`: `id` binary_id,
  `ran_at` utc_datetime not null, `account_id` references(`accounts`, binary_id,
  on_delete: nilify_all, nullable), `imported_file_id` references(`imported_files`, binary_id,
  on_delete: nilify_all, nullable), `file_path` string not null (denormalized, survives row
  loss), `status` string not null, `imported_count` integer default 0,
  `skipped_count` integer default 0, `failed_count` integer default 0,
  `error_message` text, timestamps; index on `ran_at`.
- `lib/cash_lens/imports/imported_file.ex` — Ecto schema + changeset (binary_id PK, utc_datetime
  timestamps, unique constraint on `path`).
- `lib/cash_lens/imports/import_run.ex` — Ecto schema + changeset, `status` validated by
  inclusion in the three values above.
- `lib/cash_lens/imports.ex` — the context: `scan/1`, `relative_path/2`,
  `get_imported_file_by_path/1`, `upsert_imported_file/1` (on_conflict replace of
  `content_hash`/`mtime`/`last_imported_at`/`updated_at`, conflict target `path`),
  `record_run/1`, `list_recent_runs/1` (default limit 20, newest first, account preloaded).
- `lib/cash_lens/parsers/directory_importer.ex` — three changes, no change to what `run/2`
  does for users: (a) expose the private `classify/1` as a public `account_dirs/1` returning
  `{account_dirs, skipped_dirs}`; (b) make `partition_files/2` public (`@doc false`) so `scan/1`
  reuses the recursive `**/*` walk instead of re-implementing it; (c) line 235 — `run/2` passes
  its own `path` through as `import_root:` on its `Ingestor.import_file/3` call
  (`Ingestor.import_file(account, file, dry_run: dry_run, import_root: root_path)`), which is
  the plumbing decision 3 requires. `preflight/1` and the dry-run branch (line 233) are
  untouched.
- `lib/cash_lens/parsers/ingestor.ex` — add the recording helper and call it from the three
  sites named in Behavior above (lines 95–96, 152–155 guarded by `dry_run == false`, and the
  non-dry-run branch at 164–169); thread the raw `content` through so the hash is over raw
  bytes.
- `test/cash_lens/imports_test.exs` — new test module (uses `tmp_dir` fixtures for the fake
  `.account` trees).

### Test criteria

`test/cash_lens/imports_test.exs` covers: a fresh file classified `:new`; the same file after a
recorded import classified `:synced`; the same file classified `:updated` after (a) only its
content changes and (b) only its mtime changes (`File.touch!/2` with a future timestamp);
a file in a folder without `.account` absent from the results; a dangling symlink absent from
the results without raising; a recorded path deleted from disk absent from the results with its
row still present; `relative_path/2` for a file under and outside the root; a real
`import_file/3` writing one `imported_files` row and exactly one `import_run` with counts equal
to the returned summary; a second `import_file/3` on the same unchanged file adding a second
`import_run` with `imported_count: 0` and no second `imported_files` row; an `import_file/3`
on a non-existent path and one on a file the parser rejects, each writing one `"error"` run
with zero counts and an `error_message`, while the same two cases with `dry_run: true` write
nothing; a `DirectoryImporter.run(root, [])` over a tmp `.account` tree storing
`imported_files.path` root-relative (asserted not to start with `/`) and a following
`scan(root)` returning that file as `:synced`; a file whose extension does not match the
account's `parser_type` absent from `scan/1`'s results; and a `dry_run: true` call leaving both
tables empty.

## Expected Results

- [ ] A migration creates `imported_files` with `path`, `content_hash`, `mtime`,
      `last_imported_at` and a unique index on `path`
- [ ] A migration creates `import_runs` with `ran_at`, `account_id`, `file_path`, `status`,
      `imported_count` and `skipped_count`
- [ ] `CashLens.Imports.scan/1` returns, for a monitored root, every supported file under a
      `.account` tree with `status` `:new`, `:updated` or `:synced`
- [ ] `scan/1` returns `:updated` when the recorded `content_hash` or `mtime` differs from disk,
      and `:synced` only when both match
- [ ] `scan/1` omits files not under a `.account` tree, unreadable files, and recorded paths
      that no longer exist on disk, without raising
- [ ] A non-dry-run `Ingestor.import_file/3` upserts the file's `imported_files` row and
      creates exactly one `import_run` whose `imported_count`/`skipped_count` equal the summary
      it returned
- [ ] `import_runs.status` is one of `"success"`, `"warning"`, `"error"`, with `"error"` runs
      carrying zero counts and an `error_message`
- [ ] Re-importing an unchanged file creates an additional `import_run` with
      `imported_count: 0` and does not create a second `imported_files` row
- [ ] A `dry_run: true` import writes no `imported_files` and no `import_runs` row, and a test
      asserts it
- [ ] `DirectoryImporter.run/2` passes its monitored root to `Ingestor.import_file/3`, so a
      batch-imported file is stored with a root-relative `imported_files.path` and a following
      `scan/1` on that root reports it `:synced`
- [ ] `scan/1` excludes files whose extension does not match the account's `parser_type`
- [ ] `test/cash_lens/imports_test.exs` passes under `mix test`
- [ ] `mix format --check-formatted` is clean and `mix credo --strict` reports nothing on the
      touched files

## Out of Scope

- The `/imports` LiveView, its route, navigation entry, dropzone, inspection modal and history
  rendering (later parts of CL-8).
- Instrumenting the Pluggy sync path.
- Any change to parsers, dedup keys or fingerprints.
