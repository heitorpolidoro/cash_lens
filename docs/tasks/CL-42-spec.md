# CL-42 — Resolve the excluded summary category ids once per request

## Scope
`Transactions.excluded_cash_summary_category_ids/0` (private) costs 4 queries (two slug lookups, two recursive CTEs) and is invoked on each of the three summary reads a `GET /` render performs (`get_monthly_summary`, and `get_historical_summary` twice: controller and `spend_rate/4`). Its answer is identical within a request. Resolve it once per request, so the dashboard's `categories` count falls from 13 to 5 (4 for one resolution + 1 for the variable-baseline fixed-category lookup) — defect D5 in `docs/tasks/CL-38-measurements.md`.

Not included: any process-lifetime or cross-request cache (ETS, `:persistent_term`, Agent, module attribute); reducing the 4 queries of a single resolution; `excluded_report_category_ids/0` (not on the dashboard path); other CL-38 defects; changing which categories are excluded.

## Approach
Behavior: the controller (`PageController.home/2`) obtains the excluded ids one time at the start of the request and the summary reads use that value instead of recomputing it. The value must be scoped to the request by construction (passed explicitly, e.g. through an option the summary functions accept, or a public resolver whose result is handed down); it must not outlive the request, so a category created or re-parented before the next request is seen by it. Callers that do not supply the ids (other LiveViews, mix tasks, tests calling the summaries directly) keep today's behavior: the function resolves them itself, so no existing call site changes meaning. `spend_rate/4` receives the ids through whatever path it already uses to reach `get_historical_summary/1`, without the signature leaking reporting detail beyond an optional value.

Files touched:
- `lib/cash_lens/transactions.ex`: summary reads accept an optional pre-resolved id list and fall back to resolving; expose a way to resolve it once.
- `lib/cash_lens_web/controllers/page_controller.ex`: resolve once, pass to every summary read in `home/2`.
- `lib/cash_lens/forecast.ex`: only if needed to thread the value into `spend_rate/4`'s historical-summary call.
- `test/cash_lens_web/controllers/dashboard_query_budget_test.exs`: `@categories_ceiling` becomes `5 + 0`; update the comment above it to the new derivation.
- `test/cash_lens/transactions_test.exs` (or the controller test): freshness test below.
- `docs/tasks/CL-38-measurements.md`: mark D5 as done only if that file tracks status.

Test criteria: the budget test passes at `@categories_ceiling 5 + 0` with the total ceiling lowered by the same 8 queries; summaries called without the option return the same results as before; a request that follows a category change reflects it.

## Expected Results
- [ ] `dashboard_query_budget_test.exs` passes with `@categories_ceiling` equal to `5 + 0` (and `@total_ceiling` lowered by 8).
- [ ] A single `GET /` issues the excluded-ids resolution (two slug lookups, two recursive CTEs) exactly once, not once per summary read.
- [ ] A test creates a category under `transfer` (or re-parents one into it) between two requests and shows the second request's summaries exclude its transactions while the first's did not.
- [ ] `get_monthly_summary/2` and `get_historical_summary/1` called without a pre-resolved list return unchanged results, covered by the existing transactions tests passing.
- [ ] No process-lifetime cache is introduced: no ETS, `:persistent_term`, Agent or module-attribute storage of the ids.
- [ ] `mix precommit` passes.

## Out of Scope
See Scope.
