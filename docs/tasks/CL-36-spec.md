# CL-36 — Anchor the BB CSV date and time extraction to the description prefix

## Scope
`CSVParser.extract_metadata_and_clean/2` (`lib/cash_lens/parsers/csv_parser.ex`, ~line 190) finds a `dd/mm` anywhere in a BB description, uses it as the transaction date and deletes it. This task makes the extraction recognise only a genuine card-purchase `dd/mm` (optionally followed by `hh:mm`) and fixes the year inference. The extraction itself is intended and stays.

In scope: BB CSV only (single call site `do_parse_row/3`, reached via `parse_bb_row/2`). Not in scope: Bradesco and Mercado Pago parsers (they never call this function), repairing already-imported rows (see Out of Scope), and any PARC/installment logic.

## Approach
Behavior:
- A `dd/mm` counts as the purchase date only when it is a standalone token: it must not be part of a longer date (`dd/mm/yyyy`, i.e. not followed by `/` or a digit, not preceded by a digit or `/`) and must not be an installment marker (immediately preceded by `PARC`, case-insensitive, optional whitespace). A description with no such token returns the base date and the description unchanged (no `dd/mm` removal at all).
- Only the matched token is removed from the description (not every `dd/mm`-looking substring). Time (`hh:mm`) handling stays as today; separator/whitespace cleanup stays as today.
- Year inference: build the date with the base date's year; if the result is later than the base date, use the previous year (so a 30/12 purchase posted 2026-01-02 is 2025-12-30). Invalid dates (e.g. 32/13, 29/02 in a non-leap year) still fall back to the base date.
- Existing behavior kept: `COMPRA NO DEBITO 24/02 14:30 - SUPERMERCADO` and `TRANSFERENCIA 15/03` still extract as today.

Files touched:
- `lib/cash_lens/parsers/csv_parser.ex` — anchor/qualify the date match, remove only the matched token, add the previous-year rule in `extract_metadata_and_clean/2`.
- `test/cash_lens/parsers/csv_parser_test.exs` — add cases for: full date in the middle of text untouched; purchase prefix extracted with time; December-in-January rolls back a year; `PARC 03/10` untouched; plus a `parse/2` level case through the BB path for the "Cobranca referente 17/09/2026" row.

Test criteria: the new cases above plus the existing `extract_metadata_and_clean/2` tests all pass; `mix test test/cash_lens/parsers` is green.

## Expected Results
- [ ] Parsing a BB row dated 2026-09-17 with description "Tarifa Pacote de Servicos - Cobranca referente 17/09/2026" yields date 2026-09-17 and a description still containing the literal "17/09/2026".
- [ ] Parsing a row dated 2026-06-01 with "Compra com Cartao - 30/05 21:19 PAROQUIA SANTO AGOST" yields date 2026-05-30, time 21:19 and a description without the "30/05 21:19" prefix.
- [ ] Parsing a row dated 2026-01-02 with "Compra com Cartao - 30/12 10:00 SUPERMERCADO" yields date 2025-12-30.
- [ ] Parsing a row dated 2026-09-21 with "COMPRA LOJA PARC 03/10" yields date 2026-09-21 and a description still containing "PARC 03/10".
- [ ] The existing `extract_metadata_and_clean/2` tests in `csv_parser_test.exs` and the new cases all pass.
- [ ] `parse_bradesco_row/1` and `parse_mercado_pago_row/1` do not call `extract_metadata_and_clean/2`.

## Out of Scope
- Repairing the 22 already-mangled rows ("Cobranca referente /YYYY"). The fix does not touch stored data; whether to re-import the 22 BB CSVs is the operator's decision (raised as a question).
- Any change to Bradesco or Mercado Pago parsing; CL-8 installment regrouping.
