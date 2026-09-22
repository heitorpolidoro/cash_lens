# CL-29 — Mercado Pago checking-account PDF statement parser

## Scope

Add a parser for the Mercado Pago **conta corrente** PDF statement (`EXTRATO DE CONTA`),
wire it into the existing ingestion pipeline (`AccountFile` vocabulary, `FormatDetector`
probe order, `Ingestor` dispatch), and cover it with tests.

Not covered: the Mercado Pago **card invoice** (`mercadopago_cartao_pdf`, a different
document in a different folder) is untouched; the dedup/fingerprint scheme in
`CashLens.Transactions` is untouched; `PDFConverter` is untouched; no UI change and
therefore **no HTML mockup** — this task adds a parser with no new screen.

## Findings this spec is built on (re-measured over all 20 PDFs)

Extraction via `pdftotext -layout`, the exact command
`CashLens.Parsers.PDFConverter.SystemConverter` runs.

The sample folder holds **20 PDFs**, one per month, 01/2025 through 08/2026 with no gaps.
Columns are `Data | Descrição | ID da operação | Valor | Saldo` (running balance), dates
are `dd-mm-yyyy` **with hyphens**, amounts are `R$ -48,51` — sign after the `R$` — with `.`
as thousands separator (`R$ 1.099,00`).

Two claims in the task's justification are **wrong and must not be implemented**:

1. *"There are lines with no description at all; a positional parser would read the ID as
   the description."* There is no such line. The description is **vertically centred
   around** the transaction line, occupying lines above and/or below it. The cited
   `08-02-2025 / 101754796278 / R$ -48,51` row reads, in the real layout,
   `Compra de 2 produtos` / (transaction line) / `Mercado Livre`.
2. *"The operation ID is unique per transaction and could become the dedup key."* It is
   not unique: `101754796278` carries `08-02-2025 / R$ -48,51` and
   `15-03-2025 / R$ 18,63` — a purchase and its refund sharing an order id, in two
   different files.

### Measured description shapes

Blank-line-delimited blocks over all 20 files, **407** transaction lines. Writing a shape
as `(lines above, lines below)` the transaction line:

| shape | count |
|-------|-------|
| `(0,0)` single line | 381 |
| `(1,1)` | 22 (of which **4** also carry an inline fragment between the date and the ID) |
| `(2,2)` | 4 |

Measured after noise stripping, which is the only count that means anything: **407
transactions across the 20 files, 26 of them multi-line**. Two earlier counts disagreed —
`(1,1)` 21 vs 22, and a `(1,0)` shape that does not exist. Both were measured *before*
stripping, and the phantom `(1,0)` was the `1/2` page marker sharing a block with
`14-11-2025 Rendimentos` in `pdf_260922100902.pdf`. There is no `(1,0)` shape.

**Maximum span is 4 continuation lines (2 above + 2 below), and every multi-line shape is
symmetric.** The asymmetric `3+1`, `2+3` and `1+0` shapes supposed by earlier drafts **do
not exist**. **26** transactions are multi-line (22 + 4), spread over **13 of the 20**
files. A lookahead window or a test matrix sized off "5 lines" or "3+1" is sized off
fiction.

### Segmentation rule (validated on the whole corpus)

Strip noise **positionally**, not by content match: everything above the
`DETALHE DOS MOVIMENTOS` marker (title, identity line, `CPF/CNPJ … Conta:`, `Periodo:`,
`Saldo inicial/final`, `Entradas`, `Saidas`), everything from the `Data de geração:` line
onward (SAC/ouvidoria and legal boilerplate), plus standalone `N/M` page markers and the
repeated column-header line wherever they occur.

**The form feed is stripped as a CHARACTER, never as a line.** This is not a detail. In
`pdf_260922100902.pdf` the form feed is prefixed to a transaction line itself:
`"\x0c   14-11-2025       Rendimentos       1736155503335 ..."`. Discarding lines that
*contain* `\f` therefore deletes that transaction outright — one row in 407, worth R$ 0,04,
which nobody would notice by eye. The balance-chain oracle does catch it, and that is the
best argument for keeping the oracle: this exact mistake was made and caught while
measuring the corpus for this spec.

Content matching is unsafe here and the corpus proves it: the account holder's name is
both the identity header line and part of a description —
`Pix enviado Heitor Luis` / (transaction line) / `Polidoro` in `pdf_260922101913.pdf`. A
noise rule keyed on that string eats a description.

The repeated page-2 column header is **not always present**: 19 of 20 files repeat it,
`pdf_260922100902.pdf` does not. Header stripping must tolerate its absence.

After stripping, split on runs of blank lines. Every one of the 407 blocks contains
**exactly one** transaction line; the block's other lines are that transaction's
description, read top to bottom, with the transaction line's own inline fragment inserted
in position. Reassembling this way and chaining `Saldo inicial + Σ Valor` reproduces every
intermediate `Saldo` and the `Saldo final` in all 20 files.

### The format never splits a table row across a page break — documented property

At all 20 page-1 breaks in the corpus, the last non-blank run before the `1/2` marker is a
complete transaction block (transaction line plus its full description); the first content
after the page-2 header starts a fresh block. **No transaction's description crosses a page
boundary in any of the 20 files.** The parser therefore implements **no cross-page merge
rule**, and this spec requires none. This is recorded as a property of the format, asserted
by the real-statement test below rather than assumed silently.

Consequently a block with **zero** transaction lines is not an expected outcome. Because
noise is removed positionally, stripped lines never enter a block at all, so any surviving
zero-transaction block is unrecognised content, not noise. The parser must **not** drop it
silently: it raises with the offending block's text. That is the rule that keeps "dropping
noise" from becoming "dropping content".

## Approach

### Behavior

- A new parser identifier **`mercado_pago_pdf`** is accepted everywhere a parser type is.
  The name mirrors the sibling `mercado_pago_csv` (same bank, same checking account, other
  file format) and stays distinct from `mercadopago_cartao_pdf`, where the `_cartao_`
  infix marks the card invoice.
- A new module `CashLens.Parsers.MercadoPagoPDFParser` implements the
  `CashLens.Parsers.Parser` behaviour as `parse(text, :mercado_pago_conta)`, returning
  maps with **exactly the four keys** of `Parser.transaction_map/0`:
  `%{date: Date.t(), time: nil, description: String.t(), amount: Decimal.t()}`.
  **The operation ID is not carried in the return value at all** — not as a key, not as
  data. It is used only while parsing, to locate the amount columns. It is a new module
  rather than a clause in `PDFParser` (596 lines, entirely invoice-shaped) because the
  blank-line block algorithm shares nothing with the invoice line scanners — the same
  reason `OurocardTXTParser` is its own module.
- Dates parse from `dd-mm-yyyy`; amounts from `R$ <sign><thousands>,<cents>` into
  `Decimal`, sign preserved (credits positive, debits negative); descriptions are joined
  with single spaces and trimmed.
- Noise stripping is positional, as specified above, and never reaches a description or
  produces a transaction.
- A surviving block containing zero transaction lines raises; a block containing more than
  one transaction line raises. Neither occurs in the corpus; both are programming-error
  signals, not tolerated states.
- `FormatDetector` gains a PDF-text probe for this document and returns
  `%{format: :pdf, parser_type: "mercado_pago_pdf", account_hint: %{bank: "Mercado Pago",
  credit_card: false, account_identifier: nil}}`. `account_identifier` stays `nil` even
  though the header carries `Conta: 57814615507`, because `account_identifier` is populated
  only by the OFX probe today (`format_detector.ex:218`) and every existing PDF probe
  returns `nil` (`format_detector.ex:311`); populating it for one PDF format alone would
  change hint semantics, which this task does not own.
- `Ingestor.parse/2` dispatches `"mercado_pago_pdf"` to the new module and
  `expected_extensions/1` returns `[".pdf"]` for it.
- Deduplication is **unchanged**: the existing date+description+amount fingerprint with
  per-batch occurrence index. The operation ID is never a key.

### Where the detector probe goes, and why

The probe predicate is `text contains "DETALHE DOS MOVIMENTOS"` (verified present exactly
once in all 20 checking-account PDFs and absent from the Mercado Pago card invoice and
every other sample PDF in the corpus). None of the existing markers (`Plano Contratado`,
`Total a pagar`, `Movimentações na fatura`, `Total da fatura`, `Bradesco Cartões`) occurs
in any of the 20 files — counted, zero hits — so the probe is disjoint from P1–P3 and no
placement can change an existing verdict.

It is inserted as the **new P2**, between `sem_parar_pdf` and `mercadopago_cartao_pdf`,
shifting the card probes to P3/P4. Their *relative* order — Mercado Pago before Bradesco,
which is what keeps a Mercado Pago fatura carrying `Total da fatura de <mês>` out of the
Bradesco bucket (CL-22) — is preserved exactly. Placing the account-statement probe ahead
of the fatura probes is the defensive choice should a future statement layout ever gain a
generic `Total a pagar` string. The moduledoc's documented total order is updated to
P1→P2→P3→P4 in the same commit, and `@detectable_parsers` gains the new identifier (its
compile-time subset check against `AccountFile.valid_parsers/0` then covers it).

### Files touched

- `lib/cash_lens/parsers/mercado_pago_pdf_parser.ex` — new module: positional noise
  stripping, block segmentation, description reassembly, date/amount parsing, raise on a
  zero- or multi-transaction block.
- `lib/cash_lens/parsers/account_file.ex` — add `mercado_pago_pdf` to `@valid_parsers`.
- `lib/cash_lens/parsers/format_detector.ex` — new P2 probe, `@detectable_parsers` entry,
  moduledoc detection-order update.
- `lib/cash_lens/parsers/ingestor.ex` — dispatch clause and `expected_extensions/1` entry.
- `test/cash_lens/parsers/mercado_pago_pdf_parser_test.exs` — new.
- `test/cash_lens/parsers/format_detector_test.exs`, `.../account_file_test.exs`,
  `.../ingestor_test.exs` — extend.
- `test/support/fixtures/files/mercado_pago_extrato_*.txt` — new text fixtures.

### Test fixtures

Fixtures are committed as **extracted text**, not PDFs and not inline heredocs.
PDFs are excluded because the parser's input is `pdftotext` output — it never sees PDF
bytes (`PDFConverter` is mocked in tests and covered separately), and the real files are
55 KB each of personal financial data in a **public** repository (`git remote` →
`github.com/heitorpolidoro/cash_lens`, `gh repo view` → PUBLIC). Inline heredocs are
excluded because this format's whole difficulty is column offsets, indentation and
blank-line runs, which heredocs silently reformat.

The committed text fixtures are therefore **synthetic but layout-faithful**: transcribed
column positions, page-2 indentation, `1/2` / `2/2` markers, form feed and footer preserved
verbatim from the real output, with the identity header, operation IDs and monetary values
replaced by invented ones that still chain (`Saldo inicial` → rows → `Saldo final`). The
set covers every measured shape and every structural variant:

- all three shapes — `(0,0)`, `(1,1)`, `(2,2)` — plus a `(1,1)` with an inline
  fragment, a thousands separator and a negative amount;
- a two-page fixture **with** the page-2 column header repeated, and one **without** it
  (the `pdf_260922100902.pdf` variant);
- a description line whose text repeats the identity header (`Pix enviado Heitor Luis` /
  `Polidoro`), to pin the positional noise rule;
- a malformed fixture containing an orphan text block with no transaction line, to pin the
  raise.

No fixture contains a page-crossing description, because the format does not produce one.

### The real-statement test and its precondition

A second, **opt-in** test tagged `@tag :real_statements` reads the folder named by
`CASH_LENS_MP_PDF_DIR`.

**Exclude it UNCONDITIONALLY in `test_helper.exs` — do not copy how
`:requires_unprivileged_user` is excluded.** That tag is dropped only when `euid == 0`,
which means it is excluded in the container and *runs* on the host. Applying the same
condition to `:real_statements` would make it run on every host test run — exactly where
the Drive folder is reachable — and fail for everyone who has not set
`CASH_LENS_MP_PDF_DIR`. The two tags are excluded for different reasons: one is about
privilege, this one is about opt-in.

**It cannot run in the app container.** `docker-compose.yml` documents why, in the
comment where the Drive mount would otherwise go:
the Google Drive folder is deliberately not bind-mounted, because Drive placeholders cannot
be materialised through a bind mount. It runs **on the host**, and the host needs Postgres,
which the compose `db` service does not publish. The published instance comes from
`polidoro-runner`: with `./run` up, container `cash_lens-db-native` publishes `5432`. The
exact command, precondition included, is:

```
# precondition: `./run` must be running (publishes Postgres on host port 5432)
DATABASE_HOST=localhost DATABASE_PORT=5432 \
  CASH_LENS_MP_PDF_DIR="<Drive folder>" \
  mix test --include real_statements
```

The test fails with an explicit message naming `CASH_LENS_MP_PDF_DIR` when the variable is
unset, rather than passing vacuously. The default suite stays green with no Drive access
and no PII in git.

### The existing CSVs, and the `.account` file

The folder has no `.account` today, so **nothing in it has ever been imported** — neither
the CSVs nor the PDFs. The task adds, by hand, in the operator's Google Drive (outside the
repo, so no test can assert it):

```
bank: Mercado Pago
account: Conta Corrente
parser: mercado_pago_pdf
credit_card: false
```

Decision on the CSVs: **leave them in place, import nothing from them.** With
`parser: mercado_pago_pdf` declared, `Ingestor.expected_extensions/1` returns `[".pdf"]`
and the folder importer skips every `.csv` sibling — the guard, not manual deletion, is
what makes them inert, and a test asserts it. The PDFs cover 01/2025–08/2026 continuously
and the CSVs cover 01/2025–06/2026, so the overlap is **total**. The PDFs fully supersede
them. Should the operator ever import both, the unchanged fingerprint dedup absorbs the
overlap.

### Test criteria

Unit tests on the new module for: date and amount parsing including the sign-after-`R$`
and thousands-separator forms; each of the four shapes and the inline-fragment variant;
positional noise exclusion including the identity-header collision; both page-2 header
variants; the raise on an orphan block; and a balance-chain reconciliation over a whole
fixture. Detector tests for the new verdict plus regression assertions that the Mercado
Pago fatura and Sem Parar verdicts are unchanged. Ingestor tests for dispatch and
`expected_extensions/1`. A dedup regression test that two transactions sharing an operation
id both persist.

Balance assertions on committed fixtures **hard-code the expected ladder as a literal list**
in the test, since the return map has no balance field and the fixtures are committed and
stable. The `:real_statements` test instead **re-reads the `Saldo` column** from the
extracted text, because it must track files it does not own.

## Expected Results

- [ ] `"mercado_pago_pdf"` is in `CashLens.Parsers.AccountFile.valid_parsers/0`, and an
      `.account` body declaring `parser: mercado_pago_pdf` parses without error.
- [ ] `CashLens.Parsers.MercadoPagoPDFParser` declares `@behaviour CashLens.Parsers.Parser`
      and `parse(text, :mercado_pago_conta)` returns a list of maps whose key set is
      exactly `[:amount, :date, :description, :time]` — `:time` always `nil`, and no
      operation-ID key.
- [ ] `08-02-2025` parses to `~D[2025-02-08]` (hyphenated `dd-mm-yyyy`), and
      `R$ -48,51` / `R$ 1.099,00` / `R$ 0,06` / `R$ 0,09` parse to `Decimal` `-48.51` /
      `1099.00` / `0.06` / `0.09` — sign taken from after the `R$`, `.` treated as
      thousands separator.
- [ ] A `(1,1)` description is reassembled top to bottom: the `105896764502` row yields
      exactly
      `"Compra de Soprador De Ar Pó Potente Computador Notebook 110v/220v Mercado Livre"`
      (a `(2,2)` row), and the `101754796278` row of 08-02-2025 yields
      `"Compra de 2 produtos Mercado Livre"`.
- [ ] A transaction line carrying an inline fragment *and* continuation lines reassembles
      all three parts in above → inline → below order (the `12-04-2025` shape:
      `"Compra de Multímetro Digital Automotivo C/ Iluminação Bip Profissional Bekcommerce..."` — the trailing `...` is a literal ellipsis the bank prints when it truncates a long product name, not an elision in this spec).
- [ ] The `(0,0)` shape (`Rendimentos`) parses to that description alone, absorbing no
      neighbouring line; and the `(1,1)` row at `02-02-2026 / 143869767019 / R$ -20,00`
      yields exactly `"Transferência Pix enviada Heitor Luis Polidoro"` — its continuation
      line is the account holder's own name, which also appears in the document header, so
      this row fails immediately if noise is stripped by content match instead of by
      position.
- [ ] No returned description equals or contains an operation ID, the `Data Descrição ID da
      operação Valor Saldo` column header, an `N/M` page marker, a `Data de geração:` line
      or the footer boilerplate; and no such line produces a transaction. In particular a
      description reading `Pix enviado Heitor Luis` / `Polidoro` survives intact, proving
      noise is stripped by position and not by content match.
- [ ] Parsing a two-page fixture returns every transaction from both pages, including the
      indented page-2 rows, and does so both for a fixture that repeats the page-2 column
      header and for one that omits it.
- [ ] `parse/2` raises, with the offending text in the message, on a fixture containing a
      surviving block that holds no transaction line; content is never dropped silently.
- [ ] For each committed fixture, `Saldo inicial` plus the running sum of parsed amounts
      equals a hard-coded expected ladder and ends at `Saldo final`.
- [ ] The operation ID is not used as a deduplication key: a test imports
      `08-02-2025 / 101754796278 / R$ -48,51` and `15-03-2025 / 101754796278 / R$ 18,63`
      and both rows persist; `CashLens.Transactions` fingerprint logic is unmodified
      (`git diff` touches no dedup code).
- [ ] `FormatDetector.detect/2` with `:text` containing `DETALHE DOS MOVIMENTOS` returns
      `{:ok, %{format: :pdf, parser_type: "mercado_pago_pdf", account_hint:
      %{bank: "Mercado Pago", credit_card: false, account_identifier: nil}}}`, and
      `detectable_parsers/0` includes `"mercado_pago_pdf"`.
- [ ] The CL-22 probe order still resolves: a Mercado Pago fatura text containing both
      `Total a pagar` and `Total da fatura` still detects as `"mercadopago_cartao_pdf"`,
      Sem Parar text still as `"sem_parar_pdf"`, and the whole pre-existing
      `format_detector_test.exs` passes unchanged (36 tests, 0 failures).
- [ ] `Ingestor.parse(text, "mercado_pago_pdf")` routes to `MercadoPagoPDFParser` and
      returns parsed transactions; `Ingestor.expected_extensions("mercado_pago_pdf") ==
      [".pdf"]`, so a folder mixing `.csv` and `.pdf` offers only the PDFs for import.
- [ ] A test tagged `:real_statements`, excluded from the default run, passes **on the
      host** (not in the app container, which does not mount Google Drive) **while `./run`
      is up publishing Postgres on host port 5432**, invoked as
      `DATABASE_HOST=localhost DATABASE_PORT=5432 CASH_LENS_MP_PDF_DIR="<Drive folder>" mix
      test --include real_statements`. Over all 20 PDFs it asserts 407 transactions, shape
      counts `(0,0)=381 / (1,1)=22 / (2,2)=4` with 4 of the `(1,1)` carrying an
      inline fragment, a `Saldo` chain reconciling to `Saldo final` in every file, and that
      no block spans a page break. For `pdf_260922100732.pdf` specifically: 24 transactions,
      5 of them multi-line. With `CASH_LENS_MP_PDF_DIR` unset the test fails with a message
      naming the variable.
- [ ] `docker compose exec app mix test` reports 0 failures with the pre-existing
      exclusions only; `mix format --check-formatted` passes; `mix credo --strict` reports
      no more findings per touched file than the recorded baseline:
      `lib/cash_lens/parsers/ingestor.ex` 2, `lib/cash_lens/parsers/account_file.ex` 0,
      `lib/cash_lens/parsers/format_detector.ex` 0, each touched test file 0, and the new
      `mercado_pago_pdf_parser.ex` and its test 0.

## Out of Scope

- No UI change and no HTML mockup (parser-only task).
- No cross-page description merge rule: the format does not split a table row across pages.
- No change to `PDFConverter`, to the fingerprint/dedup rules, or to the Mercado Pago card
  invoice parser.
- No project-wide `mix quality_check` gate and no clean `mix credo --strict` requirement:
  the project baseline is 25 findings and clearing it is not this task's work.
- Creating the `.account` file in Google Drive is a manual one-off outside the repo; its
  content is specified above but cannot be asserted by the suite.
- Deleting or migrating the legacy CSVs, and any backfill of historical months, are
  separate operator actions.
