# CL-41 — Compute monthly volatility in one grouped query instead of one per month

## Scope
`Forecast.monthly_volatility/2` currently calls `monthly_net/1` once per month of its window (12 `transactions` queries on the dashboard; defect D4 in `docs/tasks/CL-38-measurements.md`). Replace that with one grouped query over the whole window. Not in scope: any change to the sigma/mean/since/until result shape, to the `nil` rules, or to other dashboard queries.

## Approach
Behavior:
- One query reads the net per calendar month for the window `complete_months_before/2` returns, from the first day of the oldest month to the end of the newest. It keeps the existing filters: `transfer_key` is nil, cash accounts only (`Scopes.cash_accounts_only/1`), and `sum(amount)`.
- Months absent from the result (no cash movement) are filled with `Decimal.new("0")`, in window order, so the nets list is always `months` long and sigma, mean, and the all-zero `nil` rule are unchanged.
- `monthly_net/1` is removed (its only caller is `monthly_volatility`).

Files touched:
- `lib/cash_lens/forecast.ex`: `monthly_volatility/2` builds nets from one grouped query; `monthly_net/1` deleted.
- `test/cash_lens_web/controllers/dashboard_query_budget_test.exs`: `@transactions_ceiling` goes from `20 + 0` to `9 + 0` (20 measured today, minus 11: 12 volatility queries become 1); update the derivation comment (line 67-79: "12 for `monthly_volatility/0`" becomes 1, total 9) and the "one query per month" comment on `build_transactions`. The remaining 8 are 2 monthly summary, 2 historical summary, 2 `overdue_occurrences/1`, 1 `variable_spending_total/2`, 1 `spend_rate/4` covered-days probe; none is removable within this task's scope. The original target of 8 came from CL-38's stale count of 19 and is not reachable here (see the open question).

Test criteria:
- Existing `monthly_volatility/2` tests in `test/cash_lens/forecast_test.exs` stay green unchanged (they cover the zero-month case and the `nil` case).
- The query budget test passes with the ceiling of 9 and delta 0. If the measured count is not 9, report it rather than loosening the ceiling.
- `mix precommit` passes.

## Expected Results
- [ ] `Forecast.monthly_volatility/2` issues exactly one `transactions` query for its window, and `monthly_net/1` no longer exists.
- [ ] A month in the window with no cash-account movement contributes a net of zero; the existing `monthly_volatility/2` tests pass unchanged.
- [ ] `dashboard_query_budget_test.exs` has `@transactions_ceiling` of 9 (down from 20) with delta 0 and passes.
- [ ] `mix precommit` passes.

## Out of Scope
Other dashboard query reductions (balances, accounts, categories), changing the volatility window or formula.
