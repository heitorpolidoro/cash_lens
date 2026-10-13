# CL-45 — Date a manual Rendimento entry from the account's last transaction

## Scope
The "Rendimento do Mês" adjustment on the balance page (`BalanceAdjuster`, `:rendimento` branch) currently dates the income row at the month's last day. For the running month that is a future date: invisible to every `<= today` reading (e.g. the covered-days divisor in `Transactions.spend_rate/4`) yet counted in the projected balance. This task changes only that date.

Not covered: the `:correcao` branch; the account page "Atualizar com Rendimentos" action (already dated `Date.utc_today()`); moving or redating the existing future-dated rows; the duplicate-detection rules; any UI layout (only the helper text changes, so no mock).

## Approach
Behavior: the Rendimento row is dated the account's last transaction date that falls inside the adjusted month and is on or before today (only `file`/`manual` rows count, as in `Transactions.latest_transaction_date/1`). The lookup must be bounded by today and by the month, because an unbounded max would pick up earlier future-dated rows and perpetuate the problem. Fallbacks when the account has no such transaction: for a month already past, its last day (unchanged behavior); for the running month, today. The date is never after today and never outside the adjusted month.

Files touched:
- `lib/cash_lens/transactions.ex` — add a function returning an account's latest `file`/`manual` transaction date within a given date range (or extend the existing helper with bounds); nil when none.
- `lib/cash_lens/accounting/balance_adjuster.ex` — use it to pick the date in `create_income_transaction`; update moduledoc.
- `lib/cash_lens_web/live/balance_live/index.ex` — reword the radio helper text, which says "no último dia do mês", to say the row is dated at the account's last transaction in the month.
- `test/cash_lens/accounting/balance_adjuster_test.exs` and `test/cash_lens_web/live/balance_live_test.exs` — replace the two "last day of the month" assertions and add the cases below.

Test criteria: running month with transactions on days 3 and 9 and a future-dated row on the 31st (today after the 9th) dates the Rendimento on the 9th; running month with no transactions dates it today; past month with transactions dates it at the month's last transaction in that month; past month with none dates it at month end; the duplicate-detection test still passes with the new date.

## Expected Results
- [ ] Adjusting the running month with `:rendimento` creates a row dated the account's last `file`/`manual` transaction on or before today within that month, ignoring future-dated rows.
- [ ] The created date is never later than today for the running month.
- [ ] With no qualifying transaction, a past month falls back to its last day and the running month to today.
- [ ] A past month with transactions is dated at that month's last transaction, not at a later month's.
- [ ] The duplicate guard still returns `{:error, :duplicate}` on a repeated adjustment.
- [ ] The balance page helper text no longer claims the row is dated on the last day of the month.
- [ ] `mix test` passes for `test/cash_lens/accounting/balance_adjuster_test.exs` and `test/cash_lens_web/live/balance_live_test.exs`.

## Out of Scope
Backfilling the five existing future-dated Rendimento rows; changes to `spend_rate/4`.
