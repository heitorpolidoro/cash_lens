# CL-40 — Answer the balance self-healing probe in one query, once per request

## Scope
Defect D3 of `docs/tasks/CL-38-measurements.md`. `Accounting.ensure_active_balances_healed/0`
lists the open accounts and issues one `Repo.exists?` per account. It runs from
`list_latest_balances/0` (twice per `GET /`: the controller and `Forecast.current_balance/0`) and from
`get_historical_balances/1` (once). On the fixture set that is 12 of the 15 `balances` queries and
3 of the 9 `accounts` queries. `Accounts.list_accounts/0` (controller, `Forecast.current_balance/0`,
`Forecast.card_accounts/0`) and `Accounting.list_latest_balances/0` (controller,
`Forecast.current_balance/0`) are also each read more than once per render.

Covers: (1) the probe becomes a fixed number of queries, independent of the number of open accounts;
(2) one `GET /` runs the probe once and reads the account list and the latest balances once each;
(3) tightening the two ceilings in the query-budget test.

Does not cover: other dashboard query groups (installment_groups, statements, transactions,
categories, recurring_items); changing when or how `rebuild_account_balances/1` rebuilds; the
non-dashboard callers of `list_latest_balances/0` and `list_accounts/0` (LiveViews, API), whose
behaviour and signatures stay; any cache that outlives a request.

## Approach
Behavior:
- The probe finds the open accounts lacking a balance row for the current year/month with one
  set-based query (grouped, anti-join or `NOT EXISTS`), then calls `rebuild_account_balances/1` only for
  those. The query count does not scale with the number of accounts. Closed accounts stay ignored.
- The dashboard path does not repeat the probe, the account list or the latest balances. Prefer passing
  already-loaded data explicitly (`PageController.home/2` loads accounts and latest balances once and
  hands them to `Forecast` through an option or argument; the probe runs once) over hidden state. If any
  memoisation is used, it is scoped to one request and does not leak between requests or tests (no
  process-dictionary value surviving the render). Callers that pass nothing extra see unchanged behaviour,
  including self-healing when `list_latest_balances/0` or `get_historical_balances/1` is called standalone.
- The `:account` preload on latest balances adds no separate accounts query when the accounts are
  already in hand.

Files touched:
- `lib/cash_lens/accounting.ex` — single-query probe; a way for a caller that already ran it to skip it.
  The file has unrelated staged/unstaged edits: work around them, do not revert them.
- `lib/cash_lens/forecast.ex` — `current_balance/0` and `card_accounts/0` take accounts / latest balances
  from the caller instead of re-reading.
- `lib/cash_lens_web/controllers/page_controller.ex` — loads accounts and latest balances once and passes
  them down.
- `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` — `@balances_ceiling` to `<= 6`,
  `@accounts_ceiling` to `<= 5`, deltas stay 0; update the derivation comments.
- `test/cash_lens/accounting_test.exs` — rebuild-on-missing test and probe query-count test.
- `docs/tasks/CL-38-measurements.md` — optional one-line note that D3 is resolved.

Test criteria:
- Budget test green at the new ceilings, `>= 1` lower bounds still satisfied.
- Delete an open account's current-month balance, call `list_latest_balances/0` (or
  `get_historical_balances/1`), assert the row exists again.
- With all accounts healthy, the probe issues the same number of queries for 2 and for 6 open accounts
  (`CashLens.QueryCounter`); a closed account missing a balance is not rebuilt.
- `mix precommit` passes.

## Expected Results
- [ ] The healing probe issues the same number of queries for 2 and for 6 open accounts.
- [ ] A single `GET /` runs the probe once and reads the account list and latest balances once each.
- [ ] `dashboard_query_budget_test.exs` has `@balances_ceiling` <= 6 and `@accounts_ceiling` <= 5, deltas 0, and passes.
- [ ] A test deletes an open account's current-month balance and asserts it is rebuilt on the next read.
- [ ] `mix precommit` passes.

## Out of Scope
Other query groups; caching beyond the three reads named; LiveView and API callers.
