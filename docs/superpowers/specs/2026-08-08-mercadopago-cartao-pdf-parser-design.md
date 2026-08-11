# Mercado Pago credit-card PDF parser design

## Problem

The "Mercado Pago - Cartão de Crédito" account has no working import path today:
its Google Drive folder had no `.account` marker file (so batch import silently
skipped it), and even with one, there's no parser registered that understands
its fatura's PDF layout. `CashLens.Parsers.Ingestor.parse/2` only recognizes
`bb_csv`, `bradesco_csv`, `mercado_pago_csv`, `standard_ofx`, `ourocard_ofx`,
`ourocard_txt`, `sem_parar_pdf`, and `bradesco_cartao_pdf`.

## Goal

A new `mercadopago_cartao_pdf` parser type that extracts real transactions from
a Mercado Pago credit-card fatura PDF (via the existing `pdftotext -layout`
conversion path), following the same conventions the app already uses for
Bradesco's PDF-based cards, so the account can be added to `.account`-driven
batch imports.

## Non-goals

- Any change to how faturas are matched to their paying bank transaction
  (`CreditCards.Matcher`) — unaffected, works the same for any credit-card
  account regardless of parser.
- Any change to the billing-cycle (`closing_day`/`due_day`) system.
- Bulk-importing anything beyond this one PDF right now — this spec is about
  making the format understood; running it against the user's real file
  happens as this plan's final verification step.

## Real fatura format (from the user's actual July/2026 statement)

Extracted via `pdftotext -layout`, the fatura has (across several pages, with
a repeating page header):

```
Movimentações na fatura
Data Movimentações Valor em R$
17/06 Pagamento da fatura de junho/2026 R$ 1.412,10

Cartão Visa [************8978]
Data Movimentações Valor em R$
27/02 MERCADOLIVRE*7PRODUTOS Parcela 5 de 7 R$ 22,65
02/04 MERCADOLIVRE*26PRODUTOS Parcela 9 de 12 R$ 42,44
...
16/06 MERCADOLIVRE*MERCADOLIVRE R$ 76,75
...
```

Key format facts, all confirmed by reading the real file:

- Two distinct sections, each introduced by its own header line
  (`Movimentações na fatura` / `Cartão Visa [...]`) — repeated verbatim as a
  running page header on every page the table spans.
- No sign marker on the amount itself (unlike Bradesco's trailing `-` for
  credits) — sign is determined entirely by which section a row belongs to.
- Dates are `DD/MM` with no year, spanning several calendar months before the
  statement's own due month (old installment purchases still being paid off
  appear alongside new ones).
- An optional third column, `Parcela N de M`, appears between the description
  and the amount for installment purchases only.
- `Vencimento: DD/MM/YYYY` repeats as a page-header line (already matched by
  the existing dotall fallback regex in `PDFParser.extract_statement_date_or_nil/1`
  — no change needed there).
- The authoritative total is `Total a pagar` near the top of page 1
  (`Total a pagar\nR$ 1.357,95`, label and value on separate lines) — distinct
  from `Total da fatura de <mês anterior>` (a different, earlier number that
  must NOT be picked up) and from the per-table `Total` row that closes the
  transaction table.

## Parsing rules (confirmed with the user)

1. **The "Movimentações na fatura" line is imported as a credit
   transaction** (positive amount) — same treatment the app already gives
   the equivalent line on every other credit-card account. Checked the real
   data: Amazon/Ourocard/Amex accounts already carry a `"PAGAMENTO..."` /
   `"PGTO..."` transaction on the *card's own account*, positive amount,
   eventually categorized `Cartão de Crédito > Pagamento` — this parser
   follows that exact precedent. The parser itself does not set
   `category_id` (neither does any existing card parser); categorization
   happens afterward via the user or the category suggester, same as today.
2. **Every row under `Cartão Visa [...]` is a debit** (negative amount) —
   a purchase.
3. **Installment normalization:** a row with a `Parcela N de M` column gets
   `" PARC N/M"` appended to its description (e.g.
   `"MERCADOLIVRE*7PRODUTOS PARC 5/7"`), so the existing
   `CashLens.Transactions.InstallmentDetector` — which already matches on
   `\bPARC\s+(\d{1,2})\/(\d{1,2})\b` — recognizes it with zero changes to
   that module. A row with no `Parcela` column keeps its description as-is.
4. **Date year resolution** reuses the exact heuristic
   `PDFParser.resolve_purchase_date/2` already implements for Bradesco: if
   the row's month is greater than the statement (due-date) month, the year
   is `statement.year - 1`; otherwise `statement.year`. Verified against the
   real data: statement due date is 17/07/2026 (month 7); every transaction
   month in the fixture (02, 04, 05, 06, 07) is ≤ 7, so all correctly
   resolve to 2026 — no new edge case introduced.
5. **Statement total** (`total_a_pagar`, used by the fatura/billing-cycle
   system): `PDFParser.extract_total/1` is shared by every PDF-based card
   parser (dispatch is by file extension, not parser type, per
   `Ingestor.statement_meta/2`), so it's extended — not replaced — to also
   recognize a `Total a pagar` label (in addition to the existing
   `TOTAL DA FATURA` / `TOTAL PARA`), matched with the same "label then
   value, possibly on the next line" dotall style already used for
   `Vencimento`. This must not start matching any other current PDF
   format's text differently — the plan's testing covers this by re-running
   every existing PDF-parser test alongside the new one.

## Architecture

- New clause `PDFParser.parse(text, :mercado_pago_card)`: a section-tracking
  reduce over the `pdftotext`-extracted lines (mirrors the existing
  `process_lines/2` state-machine shape used for `:bradesco_card`, but keyed
  on section headers instead of a trailing `-` sign marker). Emits the same
  transaction map shape every other parser clause returns:
  `%{date:, time: nil, description:, amount:}`.
- `Ingestor.parse/2` gains a `"mercadopago_cartao_pdf" -> PDFParser.parse(content, :mercado_pago_card)` clause.
- `Ingestor.expected_extensions/1` adds `"mercadopago_cartao_pdf"` to the
  existing `[".pdf"]` group (alongside `sem_parar_pdf`, `bradesco_cartao_pdf`).
- `AccountFile.valid_parsers/0`'s list gains `"mercadopago_cartao_pdf"`.
- `PDFParser.extract_total/1`'s regex gains the `Total a pagar` alternative
  (see rule 5 above) — the only change to a function shared by other parsers.

## File cleanup already done (not part of the implementation plan)

The duplicate PDF that existed in both Mercado Pago folders was deleted from
`Conta Corrente`; the remaining copy in `Cartão de Crédito` was renamed to
`2026-07.pdf`. That folder still has no `.account` file — creating it (with
`parser: mercadopago_cartao_pdf`) is a one-line manual step the user does once
this parser exists and is merged; it is not something the implementation plan
needs to automate.

## Testing

Using the user's real fatura (already read into this conversation) as the
primary fixture, plus the full existing PDF-parser test suite re-run to guard
`extract_total/1`'s shared-regex change:

- The `Movimentações na fatura` line becomes one transaction: date 17/06/2026
  (resolved via the statement's year), description containing "Pagamento da
  fatura de junho/2026", amount `+1412.10`.
- Every `Cartão Visa [...]` row becomes one transaction with a negative
  amount matching the fatura. The fixture's 15 purchase rows sum to exactly
  `-1357.95` (hand-verified against the PDF: 22.65 + 42.44 + 22.14 + 41.29 +
  13.44 + 8.40 + 15.56 + 42.57 + 19.99 + 76.75 + 48.50 + 301.67 + 402.60 +
  201.41 + 98.54 = 1357.95), which independently matches both the fixture's
  own `Total` row closing the transaction table and the `Total a pagar`
  figure at the top of page 1 — a strong internal consistency check that the
  parser is reading the right rows.
- A row with `Parcela 5 de 7` produces description
  `"MERCADOLIVRE*7PRODUTOS PARC 5/7"`; a row with no parcela column (e.g. the
  16/06 `R$ 76,75` row) keeps its plain description, unsuffixed.
- Dates spanning Feb–Jul all resolve to year 2026 (per rule 4).
- `extract_statement_meta/1` on this fixture returns `due_date: ~D[2026-07-17]`
  and `total_a_pagar: Decimal.new("1357.95")` (from `Total a pagar`, not the
  `Total da fatura de junho` figure or the per-table `Total` row — all three
  numbers are distinct in the real fixture, so a regex picking the wrong one
  is directly observable in a test).
- Every existing test in `test/cash_lens/parsers/pdf_parser_test.exs` still
  passes unchanged, confirming the shared `extract_total/1` change doesn't
  regress `sem_parar_pdf` or `bradesco_cartao_pdf`.
- `AccountFile.validate_parser/1` accepts `"mercadopago_cartao_pdf"`.
- `Ingestor.expected_extensions("mercadopago_cartao_pdf")` returns `[".pdf"]`.
