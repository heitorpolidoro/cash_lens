# CL-22 — `CashLens.Parsers.FormatDetector`: content-based format and bank auto-detection

Part 2/7 of the CL-8 split. CL-8's universal drag-and-drop dropzone must accept a loose
file with no account context and work out, from the bytes alone, which parser can read it.
Nothing in the codebase does that today.

## Scope

Covers a single new **pure** module, `CashLens.Parsers.FormatDetector`, plus its test file.
It takes file bytes (and, optionally, a filename and pre-extracted PDF text) and returns a
verdict naming the file format, the `parser_type` the existing `Ingestor` should be called
with, and whatever can honestly be inferred about the owning account.

Does **not** cover: any UI or LiveView (that is CL-8's dropzone task); any change to
`CSVParser`, `OFXParser`, `PDFParser`, `OurocardTXTParser` or their output; any change to
`Ingestor`'s parse/dedup pipeline; any read or write of `imported_files` / `import_runs`
(CL-21) or of `Account` rows; any call to `PDFConverter` (which shells out to `pdftotext`
and would break purity); wiring the detector into any caller.

## Approach

### How parser selection works today, and where the detector fits

There is exactly one selection mechanism in the codebase, and it is **not** content-based:

- `Account.parser_type` is a stored string on the account row (`"bb_csv"`, `"bradesco_csv"`,
  `"mercado_pago_csv"`, `"standard_ofx"`, `"ourocard_ofx"`, `"ourocard_txt"`,
  `"sem_parar_pdf"`, `"bradesco_cartao_pdf"`, `"mercadopago_cartao_pdf"` — the list is
  `AccountFile.valid_parsers/0`).
- `Ingestor.parse/2` is a `case` on that string that dispatches to the parser module and
  format atom.
- `Ingestor.import_file/3` never inspects content to choose a parser: it takes
  `account.parser_type` as given. The only content-shaped check anywhere is
  `Ingestor.expected_extensions/1`, used by `DirectoryImporter` purely as a *guard* (skip a
  `.ofx` sitting in a CSV account folder) — it maps parser_type → extension, the inverse
  direction of what CL-8 needs, and cannot answer "which parser for these bytes?".
- For folder imports, the account (and hence the parser) comes from the `.account` marker
  file via `AccountFile.read/1`.

**Decision: the detector sits beside that mechanism; it does not replace or wrap it.** It
answers only the question nobody answers today — "no account is known, which parser reads
these bytes?" — and it answers it *in the existing vocabulary*, returning one of the
`AccountFile.valid_parsers/0` strings so the caller can hand it straight to
`Ingestor.parse/2` or use it to look up a matching account. There is no duplication,
because the detector never re-implements the parser_type → module dispatch (`Ingestor`
keeps that) and never re-implements parser_type → extension (`expected_extensions/1` keeps
that); it only adds bytes → parser_type. `FormatDetector` must reuse
`AccountFile.valid_parsers/0` rather than re-listing the strings, so the two lists cannot
drift.

### Behavior

`detect(content, opts \\ [])`, where `content` is a raw binary read from disk or from a
LiveView upload. Options: `:filename` (advisory only — used solely to break ties, never as
the primary signal) and `:text` (PDF text already extracted by the caller through
`PDFConverter`, since the detector must not shell out itself).

Success returns `{:ok, %{format: format, parser_type: parser_type, account_hint: hint}}`:

- `format` — `:ofx | :csv | :pdf | :txt`.
- `parser_type` — a `AccountFile.valid_parsers/0` string, or `nil` when the format is known
  but the specific bank/parser is not (the raw-PDF case, see below).
- `account_hint` — `%{bank: String.t() | nil, credit_card: boolean() | nil, account_identifier: String.t() | nil}`,
  or `nil` when nothing at all can be inferred. It is advisory: a hint for matching an
  existing `Account`, never an assertion.

Failure returns `{:error, :unrecognized}` — for empty content, for content matching no
signature, and for content whose format is recognised but whose bytes carry no usable
discriminator. The function never raises on arbitrary input, including binary garbage and
invalid UTF-8 (it must tolerate latin-1 bytes, the same way `Ingestor.prepare_content/3`
does, without assuming valid UTF-8).

### Discriminators (content, not extension)

Every probe below is stated as a named boolean condition over the input. Signatures are
taken from the real parsers and real samples, not invented.

#### Top-level order (total, first match wins)

1. **PDF text branch** — taken iff `opts[:text]` is a binary that is not blank after
   trimming. The `%PDF-` magic is **not** required on `content` in this branch: callers pass
   `pdftotext` output whose `content` may be the original PDF, the text itself, or the
   text-stub fixture `test/support/fixtures/files/sem_parar_*.pdf` (35 bytes of plain text,
   no magic). The branch always returns `format: :pdf`, with `parser_type` from the PDF-text
   probes below, or `parser_type: nil, account_hint: nil` when no PDF-text probe matches.
2. **Raw PDF** — `content` begins with the `%PDF-` magic bytes and no `:text` was given. The
   bank is not inferable (the text lives in compressed streams) → `format: :pdf`,
   `parser_type: nil`, `account_hint: nil`.
3. **OFX** — see below.
4. **Ourocard TXT** — see below.
5. **CSV** — see below.
6. Otherwise `{:error, :unrecognized}`.

OFX precedes the text formats because an SGML/XML OFX body can contain commas and
semicolons that a naive CSV probe would accept; Ourocard TXT precedes CSV for the same
reason.

#### PDF-text probes (total order P1 → P2 → P3)

The order between these three probes is itself normative, because their markers overlap in
real documents.

- **P1 — `"sem_parar_pdf"`**: text contains the literal `Plano Contratado` (the anchor of
  `PDFParser`'s `extract_plan_fee/1` regex, `pdf_parser.ex:201`).
- **P2 — `"mercadopago_cartao_pdf"`**: text contains `Total a pagar` **or**
  `Movimentações na fatura`. These are exactly the two discriminators the production code
  already keys Mercado Pago off: `pdf_parser.ex:543-549` routes total extraction by
  `Total a pagar` *because* Mercado Pago faturas also carry `Total da fatura de <mês>`
  (`pdf_parser.ex:536-542`), and `pdf_parser.ex:67` uses `Movimentações na fatura` as the
  section marker.
- **P3 — `"bradesco_cartao_pdf"`**: text contains `Total da fatura` **or**
  `Bradesco Cartões`. Both markers appear in real Mercado Pago text too
  (`pdf_parser_test.exs:602`, `:637` carry `Total da fatura de junho`), so P3 is reachable
  only after P2 has been evaluated and failed. That ordering — not the marker itself — is
  what keeps a Mercado Pago fatura out of the Bradesco bucket, and it must be stated in the
  module doc and pinned by a test.

#### OFX probe

- **O1 — format**: content matches `~r/OFXHEADER/i` (OFX 1.x SGML header) **or**
  `~r/<\?OFX|<OFX[>\s]/i` (2.x XML / bare `<OFX>` root). → `format: :ofx`.
- **`parser_type` is always `"standard_ofx"`.** No OFX sample in this repo carries `<ORG>`,
  `<FID>`, `<BANKID>` or `<ACCTID>` (the samples are the `<OFX>`/`<STMTTRN>` bodies in
  `test/cash_lens/parsers/ofx_parser_test.exs` and `ingestor_test.exs`), so there is no
  grounded match set for an `"ourocard_ofx"` rule and the detector must not invent one. Any
  Banco do Brasil belief lives in `account_hint.bank` only. Both parser types dispatch to
  `OFXParser`, whose `format` argument is ignored (`ofx_parser.ex:13`), so this costs no
  parse fidelity.
- **Credit card**: `account_hint.credit_card` is `true` iff content matches
  `~r/<CCSTMTTRN>/i`, otherwise `false`. Note this is the detector's own probe: `OFXParser`
  itself only scans `<(?:CC)?STMTTRN>` blocks and the value tags `MEMO`, `NAME`, `TRNAMT`,
  `DTPOSTED` and `BALAMT` — it never reads `<CCACCTFROM>`, `<BANKACCTFROM>`, `<ORG>`,
  `<FID>`, `<BANKID>` or `<ACCTID>`.
- **Hints**: `account_identifier` is the trimmed value of `<ACCTID>` when that tag is
  present, else `nil`; `bank` is the trimmed value of `<ORG>` when that tag is present, else
  `nil`. Never guess a bank name from anything else.

#### Ourocard TXT probe

Named conditions, evaluated on the whole content:

- `H_VENC` — content matches `~r/Vencimento\s*:\s*\d{2}\.\d{2}\.\d{4}/i`, the exact regex of
  `OurocardTXTParser.extract_due_date/1`.
- `L_TX` — at least one line matches `OurocardTXTParser`'s `@line_regex`, i.e. the leading
  `DD.MM.YYYY` transaction shape.
- `H_TOTAL` — content matches `~r/Total da fatura\s*:\s*R\$/i`
  (`OurocardTXTParser.extract_total/1`).

**Predicate: `H_VENC or L_TX`.** `H_TOTAL` is neither necessary nor sufficient and is *not*
part of the predicate — it is named here only to say so explicitly. This predicate accepts
both real fixtures in `test/cash_lens/parsers/ourocard_txt_parser_test.exs`: the full
`@sample` (all three true) and the header-only body
`"Vencimento : 16.07.2026\nTotal da fatura : R$ 1,00"` (`H_VENC` true, `L_TX` false).
On a match → `format: :txt`, `parser_type: "ourocard_txt"`.

#### CSV probes (total order C1 → C2 → C3)

Rows are `content` split on `~r/\r?\n/`, with a leading UTF-8 BOM stripped from the first
row. A row's fields are the row split on `";"` when the row contains a `;`, else on `","`.

- **C1 — `"mercado_pago_csv"`**: **any** row (not only row 1 — `CSVParser.parse/2` reaches
  the header with `Enum.drop_while`, `csv_parser.ex:28`) whose first field, trimmed, equals
  exactly `"RELEASE_DATE"`, matching `mercado_pago_header_row?/1` (`csv_parser.ex:283-285`).
- **C2 — `"bradesco_csv"`**: any row whose fields, each trimmed, begin with exactly
  `["Data", "Histórico", "Docto.", "Crédito (R$)", "Débito (R$)", "Saldo (R$)"]` — the
  verbatim header of `csv_parser_test.exs:181` / `ingestor_test.exs:26`.
- **C3 — `"bb_csv"`**: the **first non-blank row**, with each field normalised the way
  `CSVParser.normalize_header/1` does (trim, NFD, strip combining marks, downcase),
  satisfies **all** of: some field contains `"data"`, some field contains `"valor"`, and
  some field contains `"hist"` **or** `"lancamento"`. These are exactly the needles
  `bb_column_mapping/1` uses (`csv_parser.ex:116-127`), so both documented BB export
  variants pass — the `Histórico` layout of `test/support/fixtures/files/bb_sample.csv` and
  the `Lançamento`/`Detalhes` layout described at `csv_parser.ex:112-118`, which has no
  `Dependência Origem` column. No subset of the Bradesco header satisfies C3 (it carries no
  field containing `valor`), so C2 and C3 do not collide on real input; the stated order
  settles any case that is not real input.
- No CSV probe matches → `{:error, :unrecognized}`. The detector must not fall back to "some
  CSV parser" and guess.

### Honest limits on `account_hint`

- **Ourocard TXT** — bank is certain: `%{bank: "Banco do Brasil", credit_card: true, account_identifier: nil}`.
- **CSV** — the bank follows from the matched probe (Mercado Pago / Bradesco / Banco do
  Brasil); `credit_card: false` for all three (they are bank-statement exports); no account
  number is present in the header, so `account_identifier: nil`.
- **OFX** — `credit_card` is reliable (`<CCSTMTTRN>` vs not); `bank` and
  `account_identifier` come from `<ORG>` / `<ACCTID>` when those tags are present and are
  `nil` otherwise. No sample in this repo carries them, so `nil` is the expected value here.
- **PDF text** — bank follows from the matched probe (`Sem Parar` / `Mercado Pago` /
  `Bradesco`), `credit_card: true` for P2 and P3, `false` for P1 (Sem Parar is a toll
  account statement), `account_identifier: nil`.
- **Raw PDF** — nothing is inferable; `account_hint: nil`.
- In no case does the hint identify a specific local `Account`; resolving hint → account is
  the caller's job (CL-8).

### Files touched

- `lib/cash_lens/parsers/format_detector.ex` — new module: `@moduledoc`, typespecs for the
  verdict map, `detect/1` and `detect/2`, the named probes above, the top-level order, and
  the two intra-family orders (PDF text P1→P2→P3, CSV C1→C2→C3). It reuses
  `AccountFile.valid_parsers/0` to validate its own output vocabulary.
- `test/cash_lens/parsers/format_detector_test.exs` — new test file (no `DataCase`; a plain
  `ExUnit.Case, async: true`, since the module touches neither the Repo nor the filesystem).

### Test criteria

The matrix uses real samples already in the repo wherever they exist, rather than invented
data:

- **CSV / bb_csv** — `test/support/fixtures/files/bb_sample.csv`, read with `File.read!/1`,
  plus an inline `Lançamento`/`Detalhes` header row proving the second BB variant matches C3.
- **CSV / bradesco_csv, mercado_pago_csv** — the header rows of
  `test/cash_lens/parsers/csv_parser_test.exs` (`:181`, `:233`), reused verbatim, including
  a Mercado Pago body where the `RELEASE_DATE` row is **not** the first row.
- **OFX** — the `@sample_ofx` body of `test/cash_lens/parsers/ofx_parser_test.exs` for the
  bank case. The repo contains **no** `<CCSTMTTRN>` sample, so the credit-card case is
  authored inline in the new test file (that same body with the tag renamed), asserting
  `credit_card: true` and `parser_type: "standard_ofx"`.
- **TXT** — both bodies from `test/cash_lens/parsers/ourocard_txt_parser_test.exs`: the
  `@sample` statement and the header-only `"Vencimento : ... / Total da fatura : R$ 1,00"`
  string, proving `H_VENC or L_TX`.
- **PDF magic** — a minimal binary literal beginning with `%PDF-` built inline, asserting
  `parser_type: nil` and `account_hint: nil`.
- **PDF text** — one case per probe, using text lifted from `pdf_parser_test.exs`. The
  collision case is mandatory: the Mercado Pago fatura text at `pdf_parser_test.exs:602`
  (which contains both `Total a pagar` and `Total da fatura de junho`, and
  `Lançamentos futuros` at `:645`) must detect as `"mercadopago_cartao_pdf"`, not
  `"bradesco_cartao_pdf"`. A second case asserts a Bradesco text (`pdf_parser_test.exs:135`
  / `:169`) still detects as `"bradesco_cartao_pdf"`. The `sem_parar_*.pdf` fixture is valid
  input for the `:text` path but must not be used for magic-byte detection (it carries no
  `%PDF-` magic).
- **Extension contradicts content** — the `bb_sample.csv` body passed with a `.ofx`
  filename (and, conversely, an OFX body passed with a `.csv` filename) is classified by
  its content, proving the filename never participates in the decision.
- **Unrecognised** — at least binary garbage and an empty string, both asserting
  `{:error, :unrecognized}` and no raise; plus a delimited-but-unknown CSV header.
- **Precedence** — one case where an OFX body also contains comma/semicolon-delimited lines,
  asserting `:ofx` wins.
- Contract check: every non-nil `parser_type` returned by the matrix is a member of
  `AccountFile.valid_parsers/0`.

Run `mix test test/cash_lens/parsers/format_detector_test.exs`,
`mix format --check-formatted` and `mix credo` scoped to the two touched files.

## Expected Results

- [ ] `CashLens.Parsers.FormatDetector` exists at `lib/cash_lens/parsers/format_detector.ex`
      and exposes `detect/1` and `detect/2`, returning
      `{:ok, %{format: format, parser_type: parser_type, account_hint: account_hint}}`, where
      `parser_type` is a member of `CashLens.Parsers.AccountFile.valid_parsers/0` or `nil`.
- [ ] `detect/2` recognises OFX, CSV, PDF and Ourocard TXT from content signatures/headers
      (`OFXHEADER` or an `<OFX>` tag, `%PDF-` magic bytes, the C1/C2/C3 CSV header
      predicates, the Ourocard `H_VENC or L_TX` predicate), not from the file extension; a
      test proves a file whose extension contradicts its content is classified by content.
- [ ] An OFX input always yields `parser_type: "standard_ofx"`; `account_hint.credit_card` is
      `true` iff the body contains `<CCSTMTTRN>`, and `bank` / `account_identifier` are the
      `<ORG>` / `<ACCTID>` values when those tags are present and `nil` otherwise — the
      detector never returns `"ourocard_ofx"` and never guesses a bank from other tags.
- [ ] With `:text` supplied, `format` is `:pdf` regardless of `%PDF-` magic, and the probes
      are applied in the order `Plano Contratado` → (`Total a pagar` or
      `Movimentações na fatura`) → (`Total da fatura` or `Bradesco Cartões`); a test feeds
      the real Mercado Pago fatura text from `test/cash_lens/parsers/pdf_parser_test.exs`
      (which also contains `Total da fatura de junho`) and asserts
      `"mercadopago_cartao_pdf"`, while a Bradesco text asserts `"bradesco_cartao_pdf"`.
- [ ] A raw `%PDF-` binary with no `:text` returns `{:ok, %{format: :pdf, parser_type: nil,
      account_hint: nil}}`.
- [ ] Unrecognised content — including empty input, garbage bytes and a delimited-but-unknown
      CSV header — returns `{:error, :unrecognized}` explicitly, without raising and without
      guessing a parser.
- [ ] `test/support/fixtures/files/bb_sample.csv` detects as `"bb_csv"`, and an inline BB
      `Lançamento`/`Detalhes` header row (no `Dependência Origem`) also detects as
      `"bb_csv"`; the verbatim Bradesco and Mercado Pago header rows from
      `test/cash_lens/parsers/csv_parser_test.exs` detect as `"bradesco_csv"` and
      `"mercado_pago_csv"`, the latter with the `RELEASE_DATE` row not in first position.
- [ ] `account_hint` returns `%{bank:, credit_card:, account_identifier:}` with `nil` in any
      field that content alone cannot establish.
- [ ] Detection order is documented in the module `@moduledoc` as a total order (PDF text →
      raw PDF → OFX → Ourocard TXT → CSV, with P1→P2→P3 inside the PDF-text probes and
      C1→C2→C3 inside the CSV probes); a test proves an OFX body containing delimited lines
      is detected as `:ofx`.
- [ ] The module performs no DB access, no filesystem access, no `PDFConverter`/`System`
      call, and does not reference `imported_files` or `import_runs`.
- [ ] `mix test test/cash_lens/parsers/format_detector_test.exs` passes.
- [ ] `mix format --check-formatted` is clean and `mix credo` reports no NEW findings on the
      touched files (`lib/cash_lens/parsers/format_detector.ex`,
      `test/cash_lens/parsers/format_detector_test.exs`); pre-existing findings elsewhere in
      the repo are out of scope.

## Out of Scope

- Wiring `FormatDetector` into the `/imports` dropzone, `Ingestor`, or `DirectoryImporter`
  (later parts of the CL-8 split).
- Changing `Account.parser_type`, `.account` files, or `expected_extensions/1`.
- PDF text extraction itself, and any new parser or format.
