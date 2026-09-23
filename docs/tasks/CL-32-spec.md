# CL-32 — Stop counting reimbursement pairs on the month closing screen

## Scope

The month closing screen (`/months/:year/:month`) counts both legs of a reimbursement pair: the
reimbursed expense *and* the reimbursement that repays it. The same money is counted once as an
expense and once as income, inflating both KPI cards by the same amount. The dashboard already
avoids this — `CashLens.Transactions.get_historical_summary/1` carries
`where: is_nil(t.reimbursement_link_key)` — the two month breakdowns do not.

In scope: the two categorized rollup queries inside
`CashLens.Transactions.get_month_category_breakdown/2` and
`CashLens.Transactions.get_month_income_breakdown/2`, and the per-row drill-down of the
single-month view.

Not in scope: the dashboard and `get_historical_summary/1` (already correct, must not change),
`get_monthly_summary/2`, `get_historical_category_summary/1`, the transactions screen, any change
to how reimbursement links are created, and any layout change. No mockup accompanies this spec:
the screen's markup, copy and layout are untouched — only the numbers the existing elements print
change.

## Approach

### Behavior

1. **The same filter, not a variant.** Both categorized rollup queries gain
   `where: is_nil(t.reimbursement_link_key)`, character-for-character the predicate
   `get_historical_summary/1` already applies. The key is `reimbursement_link_key` alone: a link
   key is only ever written when the two legs are actually paired, so filtering on it removes both
   legs and only them.
2. **`reimbursement_status` is NOT the key.** Measured on the dev database: 125 transactions carry
   a `reimbursement_status`, 98 carry a `reimbursement_link_key`, and 27 carry a status with no
   link key (0 carry a link key with no status). A status without a link key marks an expense that
   is *expected* to be reimbursed but has not been matched to a credit yet — its money really did
   leave the account and nothing cancels it, so it must keep counting. Filtering on
   `reimbursement_status` would silently erase those 27 rows.
3. **The "Uncategorized" subqueries are already correct.** Both functions run a separate
   uncategorized subquery that already carries `where: is_nil(t.reimbursement_link_key)`. They must
   be left exactly as they are; only the two categorized rollups are missing the predicate.
4. **The drill-down follows the total.** Expanding a category row calls
   `Transactions.list_all_transactions/1` through `load_row_transactions/2` in
   `lib/cash_lens_web/live/month_live/show.ex`, which applies no reimbursement filter — so a row
   whose total no longer counts the pair would still list its legs, and the expansion would not add
   up to the header it hangs under. The drill-down therefore excludes reimbursement-linked
   transactions too, through a new **opt-in** filter key on `list_all_transactions/1` applied only
   by this screen. Opt-in, because `list_all_transactions/1` is also the transactions screen's
   query, where those rows must stay visible — a caller that does not pass the key sees exactly
   what it sees today. Justification for hiding rather than showing: the reimbursement leg is not
   "extra detail about this category's spending", it is an entry whose whole meaning is that it
   cancels another entry; leaving it in the expansion while removing it from the total produces a
   list that visibly disagrees with its own header, with nothing on screen explaining the gap. The
   pair remains fully inspectable on `/transactions`, which is the screen that owns per-transaction
   reconciliation.
5. **Consumers.** The only callers of the two functions are `build_single/1` and `month_totals/1`
   in `lib/cash_lens_web/live/month_live/show.ex` (single view and both sides of the comparison
   view). The comparison view follows automatically. Nothing else in `lib/` calls them.

### Ordering with CL-31 — both orderings are acceptable

CL-31 is at the approval gate and edits the same two functions (restricting them to cash accounts
via `CashLens.Accounts.Scopes` and pointing the expense rollup at
`excluded_cash_summary_category_ids/0`). This task must be implementable on top of either state:

- **If CL-31 has landed**, the two functions already call `CashLens.Accounts.Scopes`. Add the
  reimbursement predicate *alongside* it; remove nothing CL-31 added.
- **If CL-31 has not landed**, the functions are as at `83a2532`. Add the predicate and change
  nothing else.

Both are correct completions of this task. Every scope check below is expressed against **this
task's own staged diff** (`git diff --cached`), never against `83a2532`, because CL-31, CL-34 or
CL-35 may land first.

### Files touched

- `lib/cash_lens/transactions.ex` — add `where: is_nil(t.reimbursement_link_key)` to the
  categorized rollup of `get_month_category_breakdown/2` and of `get_month_income_breakdown/2`;
  add the opt-in reimbursement-exclusion filter key to `list_all_transactions/1`; refresh the two
  docstrings.
- `lib/cash_lens_web/live/month_live/show.ex` — `load_row_transactions/2` passes the new filter key.
- `test/cash_lens/transactions_test.exs` — new tests for both breakdowns, for the
  status-without-key case, and for `list_all_transactions/1` with and without the new key.
- `test/cash_lens_web/live/month_live_test.exs` — drill-down test.

### Test criteria

Fixture-level unit tests prove each side independently: a categorized negative transaction with a
`reimbursement_link_key` is absent from `get_month_category_breakdown/2`; a categorized positive
one is absent from `get_month_income_breakdown/2`; a categorized transaction with
`reimbursement_status: "pending"` and `reimbursement_link_key: nil` is present in both. A LiveView
test proves an expanded row omits the linked transaction. Dev-database figures for 2025-08 (the
month with the largest cash-account reimbursement volume, R$ 31.277,46 of expense and
R$ 32.177,46 of income) pin the real-world effect.

Database access: `./run` is live and is the only thing publishing Postgres on `localhost:5432`
(`docker-compose.yml` never publishes it). Run everything on the host with
`DATABASE_HOST=localhost DATABASE_PORT=5432`. Never start the compose stack while `./run` is live,
and never stop `./run` in order to test.

`mix quality_check` is not achievable here (~23 pre-existing credo findings in untouched files);
the bar is the per-file baseline, measured at spec time as **0 findings** for both
`lib/cash_lens/transactions.ex` and `lib/cash_lens_web/live/month_live/show.ex`. Credo cannot parse
`.heex`. Pre-existing unrelated failures:
`test/cash_lens_web/live/transaction_live/index_coverage_test.exs:170` (intermittent) and
`test/cash_lens_web/live/forecast_live_test.exs:554`.
`lib/cash_lens/pluggy/live_preview.ex` and `lib/cash_lens/transactions/category_suggester.ex` carry
unrelated uncommitted work and must never be staged.

## Expected Results

- [ ] 1. **Both categorized rollups filter on the link key.** In `lib/cash_lens/transactions.ex`,
      the categorized rollup query inside `get_month_category_breakdown/2` AND the one inside
      `get_month_income_breakdown/2` each contain `where: is_nil(t.reimbursement_link_key)` — the
      same predicate `get_historical_summary/1` already carries. Neither of the two functions
      references `reimbursement_status`. `git diff --cached -- lib/cash_lens/transactions.ex`
      shows the predicate added inside both functions.
- [ ] 2. **Expense side proven by test.** A test named
      `get_month_category_breakdown/2 skips transactions carrying a reimbursement_link_key` in
      `test/cash_lens/transactions_test.exs` creates two categorized negative transactions in the
      same month and category, one with `reimbursement_link_key` set and one with it `nil`, and
      asserts the returned row's total equals only the unlinked transaction's amount. It passes.
- [ ] 3. **Income side proven by test.** A test named
      `get_month_income_breakdown/2 skips transactions carrying a reimbursement_link_key` in
      `test/cash_lens/transactions_test.exs` does the same with two positive transactions and
      asserts the returned row's total equals only the unlinked transaction's amount. It passes.
- [ ] 4. **A status without a link key still counts.** A test named
      `the month breakdowns keep transactions with a reimbursement_status but no reimbursement_link_key`
      in `test/cash_lens/transactions_test.exs` creates one negative and one positive categorized
      transaction with `reimbursement_status: "pending"` and `reimbursement_link_key: nil`, and
      asserts both are still returned by `get_month_category_breakdown/2` and
      `get_month_income_breakdown/2` respectively. It passes.
- [ ] 5. **Dev-database income for 2025-08 — holds under either ordering.** In
      `DATABASE_HOST=localhost DATABASE_PORT=5432 iex -S mix` against the running dev database,
      `CashLens.Transactions.get_month_income_breakdown(2025, 8) |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.total)) |> Decimal.round(2) |> Decimal.to_string(:normal)`
      returns `"45297.00"` (it returns `"77474.46"` without this task's change), and that value
      equals the `:income` of the `%{year: 2025, month: 8}` entry of
      `CashLens.Transactions.get_historical_summary()`. The `Receitas` KPI card on
      `/months/2025/8` shows `R$ 45.297,00`.
- [ ] 6. **Dev-database expenses for 2025-08 — and the month screen now agrees with the
      dashboard.** In the SAME `iex -S mix` session, let `sum/1` be
      `fn rows -> rows |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.total)) |> Decimal.round(2) |> Decimal.to_string(:normal) end`.
      `sum.(CashLens.Transactions.get_month_category_breakdown(2025, 8))` returns `"32765.42"`
      (it returns `"64042.88"` without this task's change — this task removes exactly
      R$ 31.277,46, the 7 reimbursement-linked expense rows of that month on non-credit-card
      accounts), and that value equals the `:expenses` of the `%{year: 2025, month: 8}` entry of
      `CashLens.Transactions.get_historical_summary()`, i.e. the month closing screen's expense
      total for a month now equals the dashboard's expense figure for the same month. The
      `Despesas` KPI card on `/months/2025/8` shows `R$ 32.765,42`.
- [ ] 7. **The dashboard is untouched.** `CashLens.Transactions.get_historical_summary()` still
      returns, for `%{year: 2025, month: 8}`, `income` `45297.00` and `expenses` `32765.42`, and
      for `%{year: 2026, month: 9}`, `income` `37167.83` and `expenses` `40006.17`.
      `git diff --cached -- lib/cash_lens/transactions.ex` shows no change inside the bodies of
      `get_historical_summary/1`, `get_monthly_summary/2` or `get_historical_category_summary/1`,
      and no change to either of the two "Uncategorized" subqueries of the month breakdowns, which
      already carried `where: is_nil(t.reimbursement_link_key)`.
- [ ] 8. **The drill-down matches the row it hangs under.** A LiveView test named
      `an expanded category row omits the reimbursement-linked transactions` in
      `test/cash_lens_web/live/month_live_test.exs` expands a category row on
      `/months/:year/:month` via the `toggle_category` event and asserts the rendered expansion
      contains the description of the unlinked transaction and does not contain the description of
      a transaction of the same category and month whose `reimbursement_link_key` is set. It
      passes.
- [ ] 9. **Other callers of `list_all_transactions/1` are unaffected.** The exclusion is an opt-in
      filter key: a test named
      `list_all_transactions/1 still returns reimbursement-linked transactions when the exclusion key is absent`
      in `test/cash_lens/transactions_test.exs` calls `Transactions.list_all_transactions/1`
      without the new key and asserts a reimbursement-linked transaction is returned. It passes.
- [ ] 10. **Staged diff scope.** `git diff --cached --name-only` lists no file other than
      `lib/cash_lens/transactions.ex`, `lib/cash_lens_web/live/month_live/show.ex`,
      `test/cash_lens/transactions_test.exs`,
      `test/cash_lens_web/live/month_live_test.exs` and `docs/tasks/CL-32-spec.md`. In particular
      it does NOT list `lib/cash_lens/pluggy/live_preview.ex` or
      `lib/cash_lens/transactions/category_suggester.ex`, which carry unrelated uncommitted work
      and must remain modified-but-unstaged.
- [ ] 11. **Suite and style.** `DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=test mix test`
      passes except the two known-unrelated failures
      `test/cash_lens_web/live/transaction_live/index_coverage_test.exs:170` and
      `test/cash_lens_web/live/forecast_live_test.exs:554`. `mix format --check-formatted` passes.
      `mix credo lib/cash_lens/transactions.ex lib/cash_lens_web/live/month_live/show.ex` reports
      no issues (the measured baseline for both files is 0).

## Out of Scope

Changing `get_historical_summary/1`, `get_monthly_summary/2` or
`get_historical_category_summary/1`; changing the transactions screen's default listing; any
layout, copy or styling change on `/months`; the cash-accounts scoping of the month screen (CL-31).
