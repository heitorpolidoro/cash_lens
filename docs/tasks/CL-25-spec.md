# CL-25 — Universal drag-and-drop dropzone on `/imports`

Part 5 of 7 of the CL-8 decomposition, on top of CL-23 (the `/imports` shell, which left
`<!-- CL-25: universal dropzone -->` under the monitored-folder card), CL-22
(`CashLens.Parsers.FormatDetector`) and CL-24 (the extended dry-run `:preview` key and the
pre-write inspection drawer). This task composes those three: a loose file dropped on the
page is identified by content, attached to an account, previewed, and written only on an
explicit confirmation.

It **re-implements none of them**: no new detection rules, no second preview path, no second
drawer.

## Scope

Covers: an `allow_upload` + `live_file_input` drop area in `CashLensWeb.ImportLive.Index`;
staging the dropped bytes on disk; running them through `FormatDetector`; resolving or asking
for the owning account; feeding the staged file into CL-24's existing inspection drawer and
confirm path; cleaning up on every exit; and two small additions to `CashLens.Imports` so the
web layer keeps not referencing `CashLens.Accounts` or the PDF converter.

Does **not** cover: the recent-import history panel (CL-26); removal of the legacy modal
(CL-27) — `lib/cash_lens_web/live/transaction_live/import_modal_component.ex` must not be
modified by this task; any change to the parsers, to `FormatDetector`, to `Imports.scan/1`,
to `DirectoryImporter`, or to the dedup/fingerprint rules; creating `Account` rows from a
drop; batch/multi-file drops.

## Approach

### Decisions (binding — no implementer discretion)

**1. Upload configuration, and where it deviates from the one existing precedent.**
The repo's only `allow_upload` is `import_modal_component.ex:30`
(`accept: ~w(.csv .pdf .ofx .txt)`, `max_entries: 100`, `max_file_size: 10_000_000`,
`consume_uploaded_entries` copying to a temp file). This task keeps `accept` and
`max_file_size` **verbatim** and deviates on exactly two points, each stated here:

- `max_entries: 1` (not 100). Every drop here demands an individual decision — an account
  choice and a confirmation — so a queue of drawers would be the whole feature's complexity
  for no gain. Bulk is what the monitored folder already is.
- `auto_upload: true` with a `progress:` callback, consuming in that callback when
  `entry.done?`, instead of the legacy consume-on-form-submit. There is no form to submit:
  the drop itself is the trigger, and criterion "each dropped file is routed through
  `FormatDetector`" has to happen before any UI decision exists.

The upload name is `:drop`; the `live_file_input` sits inside a `<form id="dropzone-form"
phx-change="validate_drop" phx-submit="validate_drop">` (the form is required by
`live_file_input`; both handlers are no-ops that only keep the socket). The drop area carries
`id="dropzone"` and `phx-drop-target={@uploads.drop.ref}`. `accept` is a client-side
extension guard only — it is not detection, and a `.csv`-named OFX still gets classified by
content (CL-22's contract).

**2. The bytes are staged immediately, under a content-addressed path.**
In the progress callback, `consume_uploaded_entries(socket, :drop, &stage/2)` copies the temp
file to

```
<System.tmp_dir!()>/cash_lens_drops/<session_id>/<content_hash>/<sanitized original basename>
└──────────── Imports.drop_root/0 ────────────┘
                                 └── the session's drop root, the `import_root:` of a drop ──┘
```

where `session_id` is 8 random bytes hex-encoded in `mount/3` and kept in an assign, and
`content_hash` is `Imports.content_hash/1` over the raw bytes and the basename is
`Path.basename(entry.client_name)` (the legacy `copy_to_temp/2` convention, minus the uuid
prefix). Consuming inside the callback is mandatory: once LiveView finishes an entry the
temp file is removed, so nothing later in this flow — detection, preview, confirm — could
read it.

Two properties of this layout are load-bearing and must be preserved:

- **The original extension survives.** `Ingestor.prepare_content/3` decides whether to run
  the PDF converter with `String.ends_with?(file_path, ".pdf")`, and
  `Ingestor.statement_meta/2` switches on `.pdf` / `.ofx` / `.txt`. Renaming the staged file
  would silently break PDF text extraction and credit-card statement metadata.
- **`Path.basename/1` is still the file the operator dropped**, so a credit-card import
  stamps `statements.source_file` with the real filename (the hash is the directory, never
  the filename).

Three consequences of this layout are stated here so they are not discovered later:

- **The session subdirectory is what makes staging private.** Content-addressed staging alone
  is shared: two tabs (or a tab and a reconnect) dropping the same bytes would land on the
  same `<content_hash>/` directory, and one tab's cleanup would delete the other tab's staged
  file mid-preview. The `<session_id>` level removes the interference entirely, and it is
  invisible to decision 4 because the `import_root:` handed to the Ingestor is the *session*
  root, so the recorded key stays `"<content_hash>/<basename>"`.
- **Extension, not content, decides credit-card statement metadata.** `statement_meta/2`
  switches on the *staged filename's* extension (`ingestor.ex:203-207`), and we deliberately
  keep the dropped name. So an OFX credit-card body dropped as `extrato.csv` is parsed
  correctly as OFX by the account's parser but produces **no `credit_card_statements` row**,
  because no branch of `statement_meta/2` matches `.csv`. Transactions still import. This is
  accepted, not fixed here (fixing it means changing `Ingestor`, which this task must not
  touch); it is the price of not renaming the file, and it only affects deliberately
  mis-named credit-card files.
- **Filename length interacts with a known column limit.** The `imported_files.path` key of
  decision 4 is `"<content_hash>/<basename>"`, a fixed 65-character prefix (64 hex + `/`).
  `priv/repo/migrations/20260919120000_create_imported_files.exs:7` declares
  `add :path, :string`, i.e. `varchar(255)`, so a dropped basename longer than ~190
  characters cannot round-trip through that column. Widening the column is out of scope for
  this task; the budget is written down here, and the spec does not pretend the row survives
  a longer name.

**3. The drawer's confirm path is CL-24's, unchanged, and hash equality still applies.**
The `@inspect` assign is CL-24's `%{entry:, account:, summary:, hash:}` with an added
`source: :drop | :folder`. For a drop, `entry` is a synthetic map with the same keys the rest
of the code reads: `%{path: <original basename>, absolute_path: <staged path>, bank:,
account:, content_hash: <hash measured at staging>}`. `hash` is that same value.

`"confirm_import"` is **one handler for both sources**. It re-reads `entry.absolute_path`,
recomputes `Imports.content_hash/1`, and refuses on inequality exactly as CL-24 specifies.
The rule is kept rather than skipped even though the staging directory is private and the
hash cannot realistically change: it is the one guarantee that the confirmed bytes are the
previewed bytes, and having a second confirm path that skips it is precisely how that
guarantee would rot. The staged file **missing** at confirm time (tmp reaped, manual
cleanup) is not a hash mismatch: it renders the `:error` flash `O arquivo solto não está
mais disponível. Solte-o novamente.`, closes the drawer and clears the drop — no import,
no row.

`source` changes exactly **three** things:

1. the `import_root:` passed to `Ingestor.import_file/3` (decision 4);
2. the cleanup that runs afterwards (decision 9);
3. the missing-file rule above, which **diverges from CL-24 decision 5 on purpose**. For a
   folder entry CL-24 lets `import_file/3` run and record an *error* `import_run`, because a
   monitored file vanishing is a real, reportable import attempt. For a drop the staged file
   is our own private temp copy: its absence means the staging was reaped, not that an import
   failed, so the drop is refused **before** any `Ingestor` call and writes no `import_runs`
   row at all. Any other `source: :folder` behaviour in `"confirm_import"` is CL-24's,
   unchanged.

**4. A dropped file does produce an `imported_file` row, keyed on `<content_hash>/<basename>`.**
`Ingestor.record_import/5` always runs on a real import and always upserts an
`imported_files` row through `Imports.relative_path(file_path, Imports.import_root(opts))`;
this task does not add a suppression flag to the Ingestor. The confirm therefore passes the
**per-session staging root** of decision 2 —
`import_root: <System.tmp_dir!()>/cash_lens_drops/<session_id>` — which makes the row's key
exactly `"<content_hash>/<original basename>"`.

This is the session root, **not** `<tmp>/cash_lens_drops`. Passing the base directory instead
would make `Imports.relative_path/2` (called from `Ingestor.record_import/5`,
`ingestor.ex:475`) yield `"<session_id>/<content_hash>/<basename>"` — a key that is no longer
content-addressed and that a re-drop of the identical file in a new session would never hit
again, defeating the very property this decision exists to give.

Justification, since this is the decision most easily got wrong:

- Keying by the absolute staged path (what `import_root: nil` would give) writes a row for a
  temp path that is deleted seconds later and never returns — an unbounded pile of dead rows
  that means nothing.
- The content hash **is** the only stable identity a loose file has. The resulting key is
  honest: "these exact bytes, under this name, were imported". Re-dropping the identical file
  hits the same row and refreshes `last_imported_at` instead of creating a second one.
- It cannot collide with a monitored-folder key, which is always `<account dir>/<file>`
  relative to the root, and it is never listed by `Imports.scan/1`, which only walks the
  monitored root — so no ghost row appears in the file list.

The `import_runs` row is written by the same call, with `file_path` equal to that key. That
is deliberate: it is a genuinely executed import and CL-26 will show it. Nothing about the
history panel is built here.

**5. Account resolution: the format decides eligibility, the parser and the hint only rank,
the operator decides.**
CL-22 is explicit that `account_hint` fields are `nil` whenever content cannot establish
them (always for `account_identifier` on CSV/TXT/PDF, and for `bank` on every OFX sample in
this repo), and that the hint never identifies a local `Account`. **A drop is therefore never
imported into an account inferred by the detector alone.** The flow is:

- New `CashLens.Imports.candidate_accounts/1` takes the detector verdict and returns the
  importable accounts (`accepts_import and not is_closed`) that satisfy **one** predicate,
  and no other:

  > `extension_of(verdict.format) in Ingestor.expected_extensions(account.parser_type)`,
  > with `extension_of` being `:ofx → ".ofx"`, `:csv → ".csv"`, `:pdf → ".pdf"`,
  > `:txt → ".txt"`.

  That is the **same-extension family**. `verdict.parser_type` never removes an account from
  the list: it only ranks (below) and is displayed. The account's own `parser_type` is what
  the import uses; dispatch is never re-implemented here.

  Equality on `parser_type` was the earlier rule and is wrong. Decided over the real
  `AccountFile.valid_parsers/0` set (`lib/cash_lens/parsers/account_file.ex:29`), account by
  account:

  | account `parser_type` | ext | can the detector ever emit it? | under equality |
  |---|---|---|---|
  | `bb_csv`, `bradesco_csv`, `mercado_pago_csv` | `.csv` | yes (CL-22 probes C1–C3) | reachable |
  | `standard_ofx` | `.ofx` | yes | reachable |
  | `ourocard_ofx` | `.ofx` | **never** — CL-22's OFX probe fixes `parser_type` to `"standard_ofx"`, since no repo sample carries `<ORG>`/`<FID>` | **permanently unreachable** |
  | `ourocard_txt` | `.txt` | yes | reachable |
  | `sem_parar_pdf`, `bradesco_cartao_pdf`, `mercadopago_cartao_pdf` | `.pdf` | only when a PDF-text probe matches; the raw-PDF verdict is `parser_type: nil` | unreachable for every PDF without usable text |
  | `nil` / anything else | `[]` | — | never a candidate |

  So equality locks `ourocard_ofx` accounts out of the feature forever and locks every PDF
  account out whenever `pdftotext` yields nothing — the "Zero candidates" dead end, with no
  override, because the select lists only candidates. The family predicate costs nothing in
  fidelity for the OFX pair (both dispatch to the same `OFXParser`, whose `format` argument
  is ignored, `ofx_parser.ex:13`) and, for the other families, offers the operator a choice
  they can see and correct rather than a refusal they cannot. An account with a `nil` or
  unknown `parser_type` stays excluded on purpose: `expected_extensions/1` returns `[]` for
  it and `Ingestor.parse/2` could not dispatch it anyway.

- Ordering and pre-selection, in this order, first match wins:
  1. exactly one candidate → selected;
  2. otherwise exactly one candidate whose `parser_type` equals a **non-`nil`**
     `verdict.parser_type` → selected;
  3. otherwise exactly one candidate whose `bank` matches `hint.bank` case-insensitively
     (after `String.trim/1`) → selected. **When `account_hint` is `nil` (the raw-PDF verdict)
     or `hint.bank` is `nil` (every OFX sample in this repo), this rule cannot fire and is
     skipped** — it is never treated as "matches everything";
  4. otherwise **nothing is selected**.
- The control is a `<select id="drop-account" name="account_id" phx-change="select_drop_account">`
  listing the candidates as `"<bank> · <name> (<parser_type>)"` — exact `parser_type` matches
  first, then the rest of the family — always rendered (even when pre-selected, so a wrong
  guess is correctable). When the selected account's `parser_type` differs from a non-`nil`
  detected one, the drawer shows `Compatível pelo formato — o extrator da conta é que será
  usado.` With no selection the drawer shows the picker, the copy
  `Escolha a conta desta importação.`, **no preview** and a `disabled` confirm button.
- Choosing an account runs the dry run for that account and fills the drawer. Re-choosing
  re-runs it. The preview must be computed with the selected account, because both the
  parser and the fingerprint (`account_id`) depend on it — a preview from another account
  would be a different import.
- **Zero candidates** — now meaning "no importable account handles this extension at all",
  not "no account matches the detected parser" → the drawer opens on CL-24's `#inspect-error`
  block with `Nenhuma conta compatível com este formato.`, no preview, no confirm button; the
  staged file is discarded on close.

**6. The unrecognised case leaves nothing behind.**
`{:error, :unrecognized}` from the detector (and an unreadable staged file) →
`File.rm_rf/1` on the drop's `<content_hash>` staging directory **in the same callback**, an
on-screen `#drop-error` block naming the file and reading `Formato não reconhecido: <name>.`
plus a hint that the file may not be a supported statement, `@drop` cleared to `nil`, the
drawer never opened. No `Ingestor` call, therefore no `import_runs` row, no `imported_files`
row, no `transactions` row, no retained temp file. The error block carries a `Dispensar`
button (`phx-click="clear_drop"`).

A recognised **format** whose bank is unknown (`parser_type: nil`, CL-22's raw-PDF verdict)
is **not** the unrecognised case: it proceeds to decision 5 — where the candidate list is the
same `.pdf` family either way, only unranked by parser and unrankable by bank hint, since
`account_hint` is `nil` — and the detection line reads `PDF · banco não identificado`.

**7. PDF text extraction is a two-phase detection, and it lives in the context.**
`FormatDetector` must not shell out (CL-22). New `CashLens.Imports.detect_file/1` therefore
owns the sequence, so neither the converter nor `CashLens.Accounts` is referenced from
`lib/cash_lens_web/live/import_live/`:

1. `File.read/1` the staged path → `{:error, :unreadable}` on failure.
2. `FormatDetector.detect(content, filename: basename)`.
3. Only when that returns `{:ok, %{format: :pdf, parser_type: nil}}`, call the configured
   `Application.get_env(:cash_lens, :pdf_converter).convert(path)` and, on `{:ok, text}` that
   is non-blank, re-run `FormatDetector.detect(content, filename: basename, text: text)` and
   return the second verdict. Converter error, or a verdict still carrying `parser_type: nil`,
   returns the first verdict unchanged.
4. Returns `{:ok, verdict}` | `{:error, :unrecognized}` | `{:error, :unreadable}`.

The converter runs a second time inside `Ingestor.prepare_content/3` at preview and at
confirm. No caching is introduced: sharing extracted text between the detector and the
Ingestor would mean the previewed text and the imported text could differ from the file, for
a saving that does not matter on a local single-user screen. Tests must therefore stub the
converter (`Mox.stub/3`), not `expect` a fixed arity.

**8. Synchronous, like CL-23 and CL-24.** No `Task`, no PubSub. Staging, detection, the PDF
conversion and the dry run all happen inline in the progress callback / event handler.

**9. Cleanup is total and has one owner.** The staging directory of a drop is removed by
`File.rm_rf/1` on every one of these, and there are no others:

- unrecognised or unreadable detection;
- `"clear_drop"`;
- closing the drawer on a drop (`"close_inspect"` with `source: :drop`, covering Cancelar,
  backdrop and Esc);
- after a confirm, success or failure;
- **a new drop replacing the current one** (decision 10);
- `terminate/2`, which removes the whole `<drop_root>/<session_id>` directory.

`terminate/2` is best-effort only: it does not run on a LiveView crash, on a `:brutal_kill`
shutdown, or when the VM is killed, so it cannot be the last line of defence. Therefore
`mount/3` also performs a **stale-session sweep**: it lists `<tmp>/cash_lens_drops`, and
`File.rm_rf/1`s every session directory other than its own whose `File.stat!/1` `mtime` is
older than 24 hours. Age-bounded, so a second live tab's in-flight staging is never deleted;
best-effort, so a failing `File.ls/1` (the root may not exist yet) is ignored, never raised.

The invariant asserted by the tests is simply that `<tmp>/cash_lens_drops/<session_id>`
contains no directory for the drop after each of the paths above.

**10. A second drop replaces the first; it is never queued and never silently dropped.**
`max_entries: 1` bounds *concurrent* entries only: the moment the progress callback consumes
an entry it leaves the upload list, so nothing in LiveView stops the operator from dropping
file B while the drawer is still open on file A, or while a CL-24 folder inspection is open.
The rule, evaluated at the **top of the progress callback, before the new bytes are staged**:

- `@drop` is non-`nil` → its staging directory is `File.rm_rf/1`'d and `@drop` set to `nil`
  *first*. The new drop then proceeds normally. Nothing is left in
  `<drop_root>/<session_id>/` from file A.
- `@inspect` is non-`nil` → it is discarded whatever its `source`. With `source: :drop` that
  is the same drawer being re-rendered for the new file; with `source: :folder` the folder
  inspection is simply closed — nothing to clean up, since a folder entry owns no staged
  file. The drawer then re-opens for the new drop (or `#drop-error` renders, if the new drop
  is unrecognised).

Replace, not reject, because the alternative is a modal trap: rejecting the second drop while
a drawer is open means an operator who dropped the wrong file must find the Cancelar button
before the page will accept anything, and a rejection has no natural place to be shown while
a drawer covers the screen. The last file the operator dropped is unambiguously the one they
meant. The cost — a preview the operator never confirmed is thrown away — is exactly what
Cancelar does anyway, and nothing was written.

**11. After a confirmed drop the list is re-scanned** through CL-23's `assign_scan/2`, the
same as CL-24's confirm. The dropped file is not in the monitored root so its own row does
not appear; re-scanning anyway keeps a single confirm code path, which is worth more than the
skipped work.

### Behavior

- `/imports` renders, under the monitored-folder card (replacing CL-23's HTML comment), a
  dashed drop area `#dropzone` containing a `live_file_input` and the copy
  `Arraste um extrato aqui (OFX, CSV, PDF ou TXT) ou clique para escolher`.
- Dropping/choosing one file uploads it, stages it, detects it, and then either:
  - renders `#drop-error` (unrecognised / unreadable / too large / rejected extension — the
    last two come from `@uploads.drop.errors`, rendered in the same block), or
  - opens CL-24's `#inspect-drawer`, whose header now also renders `#drop-detection` with the
    format label (`OFX` / `CSV` / `PDF` / `TXT`), the detected parser or
    `banco não identificado`, the original filename, and the `#drop-account` select.
- With an account selected the drawer body is exactly CL-24's: `#preview-new-count`,
  `#preview-skipped-count`, the `[data-preview-row]` table with its 200-row truncation, and
  `Confirmar importação`.
- Confirming writes for real and flashes CL-24's `N transações importadas, M duplicadas
  ignoradas.`; the drawer closes and the drop is cleared.

### Files touched

- `lib/cash_lens_web/live/import_live/index.ex` — `allow_upload(:drop, …)` in `mount/3`; the
  dropzone markup replacing the CL-25 comment; `handle_progress/3`; `handle_event/3` for
  `"validate_drop"`, `"select_drop_account"` and `"clear_drop"`; the `source: :drop` branch
  inside the existing `"confirm_import"` and `"close_inspect"`; the `@drop` assign; the
  `#drop-detection`, `#drop-account` and `#drop-error` markup; the `session_id` assign and
  the stale-session sweep in `mount/3`; the replace-the-previous-drop step at the top of
  `handle_progress/3` (decision 10); `terminate/2`.
- `lib/cash_lens/imports.ex` — add `detect_file/1` and `candidate_accounts/1`, plus the
  staging helpers (`drop_root/0`, the per-session root used as the `import_root:` of a drop,
  and the stale-session sweep); nothing existing changes.
- `test/cash_lens_web/live/import_live_test.exs` — new `describe "universal dropzone"`.

Not touched, explicitly: `lib/cash_lens_web/live/transaction_live/import_modal_component.ex`,
`lib/cash_lens/parsers/format_detector.ex`, `lib/cash_lens/parsers/ingestor.ex`.

### Test criteria

In `test/cash_lens_web/live/import_live_test.exs`, reusing CL-23's mandatory
`last_batch_import_path` save/restore `setup` and its tmp-root fixtures, with
`file_input(view, "#dropzone-form", :drop, [%{name:, content:, type:}])` + `render_upload/2`
(the idiom of `import_modal_coverage_test.exs:121`):

1. **One upload per supported format**, each with an `account_fixture` whose `parser_type`
   matches so the candidate is unique and auto-selected, asserting `#inspect-drawer` is
   rendered and `#drop-detection` names the format and parser:
   - CSV — `test/support/fixtures/files/bb_sample.csv` read with `File.read!/1`, account
     `bb_csv`;
   - OFX — the `@sample_ofx` body from `test/cash_lens/parsers/ofx_parser_test.exs`, account
     `standard_ofx`;
   - TXT — the Ourocard `@sample` from `test/cash_lens/parsers/ourocard_txt_parser_test.exs`,
     account `ourocard_txt`;
   - PDF — content starting with the `%PDF-` magic bytes, with
     `Mox.stub(CashLens.Parsers.PDFConverterMock, :convert, fn _ -> {:ok, sem_parar_text} end)`
     and `Mox.allow(CashLens.Parsers.PDFConverterMock, self(), view.pid)` after `live/2`,
     asserting the detection line resolves to `sem_parar_pdf`.
2. **Unrecognised**: uploading binary garbage named `lixo.csv` renders `#drop-error`, renders
   no `#inspect-drawer`, and leaves the `transactions`, `imported_files` and `import_runs`
   counts unchanged; `File.ls!` of `<tmp>/cash_lens_drops` gains no directory.
3. **Content over extension**: the OFX body uploaded as `extrato.csv` still detects as OFX
   and offers the `standard_ofx` account — the one test that proves the detector, not the
   `accept` list, decides.
3b. **`ourocard_ofx` is reachable** (decision 5): with the only importable account being an
   `ourocard_ofx` one, the OFX body drop renders `#drop-account` containing that account and
   does **not** render `Nenhuma conta compatível com este formato.`. The same test asserts
   that a `.csv` drop does not list it, i.e. the family predicate is by extension and not
   "everything".
4. **No write before confirmation**: with the drawer open on a recognised drop, the four
   counts of CL-24 criterion 2 are unchanged; closing the drawer leaves them unchanged and
   removes the staging directory.
5. **Confirm writes**: confirming a CSV drop grows `transactions` **in that account** by
   `#preview-new-count`, creates exactly one `import_runs` row, creates an `imported_files`
   row whose `path` is `"<content_hash>/bb_sample.csv"`, and removes the staging directory.
6. **Ambiguous account**: two `bb_csv` accounts with different banks and a hint that matches
   neither → the drawer renders `#drop-account` with no selection, no `[data-preview-row]`,
   and a disabled confirm; firing `"select_drop_account"` renders the preview.
7. **No candidate**: no importable account whose `expected_extensions/1` covers the detected
   format (e.g. only a `bb_csv` account, and a `.txt` Ourocard drop) → `#inspect-error`, no
   confirm button, staging directory removed on close.
7b. **A second drop replaces the first** (decision 10): drop the CSV sample, assert the drawer
   is open, then — without closing it — drop the OFX sample. The drawer now shows the OFX
   detection and the OFX candidates, and `<drop_root>/<session_id>` contains exactly one
   staging directory, the OFX one. A companion assertion covers the `source: :folder`
   collision: with a CL-24 folder inspection open, a drop replaces it with the drop drawer.
7c. **Stale-session sweep** (decision 9): create `<tmp>/cash_lens_drops/<fake_session>/x/` and
   backdate its `mtime` beyond 24 h via `File.touch!/2`, then `live(conn, ~p"/imports")`; the
   directory is gone. A second, freshly-touched fake session directory survives.
8. `mix test test/cash_lens_web/live/import_live_test.exs` passes, together with
   `test/cash_lens_web/live/transaction_live/import_modal_component_test.exs` and
   `import_modal_coverage_test.exs` unchanged (proof the legacy path was not touched).

## Expected Results

See the checklist below; it is the same list returned to the task.

- [ ] `CashLensWeb.ImportLive.Index` declares `allow_upload(:drop, accept: ~w(.csv .pdf .ofx
      .txt), max_entries: 1, max_file_size: 10_000_000, auto_upload: true, progress: …)` and
      renders a `live_file_input` inside `#dropzone` carrying `phx-drop-target`
- [ ] Every dropped file is staged to disk and routed through
      `CashLens.Parsers.FormatDetector` (via `CashLens.Imports.detect_file/1`, which also
      supplies extracted PDF text), and the screen renders `#drop-detection` showing the
      inferred format and the detected parser or `banco não identificado`
- [ ] A dropped file whose content does not match the extension is classified by content: a
      test uploads an OFX body named `.csv` and the screen reports OFX
- [ ] Unrecognised content renders `#drop-error`, opens no drawer, writes no `transactions`,
      `imported_files` or `import_runs` row, and leaves no staged file behind
- [ ] A recognised drop opens CL-24's `#inspect-drawer` with the preview counts and rows, and
      nothing is written until `Confirmar importação` is clicked; a test asserts the four row
      counts are unchanged while the drawer is open
- [ ] The account is never inferred from `account_hint` alone: the drawer renders a
      `#drop-account` select of every importable account whose
      `Ingestor.expected_extensions(account.parser_type)` covers the detected format — so an
      `ourocard_ofx` account is offered for an OFX drop even though the detector only ever
      emits `standard_ofx` — pre-selected only when the choice is unique, or a unique exact
      `parser_type` match, or a unique bank-hint match, and confirm is disabled until an
      account is selected
- [ ] Zero accounts compatible with the detected format renders `#inspect-error` with no
      confirm button
- [ ] Confirming re-reads the staged bytes and compares the content hash exactly as CL-24
      specifies before importing; a staged file that is gone at confirm time is refused with
      an error flash and writes nothing
- [ ] A confirmed drop writes an `imported_files` row keyed `"<content_hash>/<original
      filename>"` and one `import_runs` row with the same `file_path`, and the new
      `transactions` in that account equal `#preview-new-count`
- [ ] A drop arriving while a drawer is already open (on a previous drop or on a CL-24 folder
      inspection) replaces it: the new file's drawer is shown and the previous drop's staging
      directory is removed, leaving exactly one staging directory for the session
- [ ] The staged file is removed after confirming, after cancelling/closing the drawer, on an
      unrecognised drop, when a new drop replaces it, and in `terminate/2`; `mount/3`
      additionally sweeps `cash_lens_drops` session directories older than 24 hours, and a
      test proves a backdated directory is removed while a fresh one survives
- [ ] `test/cash_lens_web/live/import_live_test.exs` simulates one upload per supported
      format (OFX, CSV, PDF, TXT) plus the unrecognised case, the replaced-drop case and the
      `ourocard_ofx` candidate case, and passes under `mix test`
- [ ] `lib/cash_lens_web/live/transaction_live/import_modal_component.ex` is unmodified
      (CL-27 owns it) and no import-history panel (CL-26) is implemented
- [ ] `mix format --check-formatted` is clean and `mix credo` reports no NEW findings in the
      files this task touches (pre-existing findings elsewhere in the repo are out of scope)

## Out of Scope

- CL-26 recent-import history, CL-27 legacy modal removal.
- Multi-file drops, creating accounts from a drop, editing `.account` files.
- Any change to `FormatDetector`, the parsers, `Imports.scan/1`, `DirectoryImporter`, or the
  dedup/fingerprint rules.

Interactive mockup: `docs/tasks/CL-25-mock.html`
