# CL-46 — Closing-day notice must wait until the day after closing

## Scope
Root cause: `CreditCards.closed_without_statement/2` (feeds the dashboard's "Fatura possivelmente fechada" warning) treats a cycle as closed when its closing date is `<= today`. On the closing day itself the bank has not yet issued the bill (e.g. Mercado Pago closing today is available tomorrow), so the warning fires a day early. A cycle must count as closed only when its closing date is strictly before today.

Not covered: `pending_cycles/2` (`cycle_closed?`, `today.day > closing_day`) already uses the strict rule and stays as is; no UI/copy change; no mock.

## Approach
- `lib/cash_lens/credit_cards.ex`: in `closed_competencias/3`, the latest closing is this month's closing only when it is strictly before `today`; on the closing day itself it falls back to the previous month's closing. Update the `closed_without_statement` doc to say the bill is available the day after closing.
- `test/cash_lens/credit_cards_test.exs` (`closed_without_statement/2` describe): add a case where `today` equals the closing day (no gap reported for that cycle) and one for the day after (gap reported, `closed_on` is the closing date). Adjust any existing case that puts `today` exactly on a closing day.

## Expected Results
- [ ] On the closing day itself, `closed_without_statement/2` does not report that cycle.
- [ ] The day after closing, it reports the cycle with `closed_on` equal to the closing date.
- [ ] The dashboard `#closed-statement-warning` is absent on the closing day and present the next day for a card without a statement.
- [ ] `pending_cycles/2` behavior is unchanged and its tests pass.
- [ ] `mix test test/cash_lens/credit_cards_test.exs test/cash_lens_web/controllers/page_controller_test.exs` passes.

## Out of Scope
Statement-list lifecycle badges, due-date urgency labels, forecast logic.
