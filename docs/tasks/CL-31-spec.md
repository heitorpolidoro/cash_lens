# CL-31 — Make the month closing screen a cash-basis view of current accounts

## Scope

The month closing screen (`/months/:year/:month`) must report **money that actually left or
entered a current (non credit-card) account** in the month. Today it is an accrual view — card
purchases counted under their own categories, the bill payment excluded — while the dashboard
(`get_historical_summary/1`) is a cash view, and the two disagree (R$ 25k vs R$ 40k for 2026-09)
with nothing on screen explaining the gap.

In scope: `CashLens.Transactions.get_month_category_breakdown/2` and
`get_month_income_breakdown/2`, the parent-transaction exclusion those breakdowns apply, the
per-row drill-down of the single-month view, and the screen's own subtitle.

Not in scope: the dashboard, `get_historical_category_summary/1` (no web caller; stays accrual),
`get_monthly_summary/2`, the comparison view's arithmetic (it consumes the same two functions and
follows automatically), and any per-category breakdown of card spending — the operator explicitly
accepted losing it here and will revisit it in a later task.

## Approach

### Behavior

1. **Cash accounts only.** Every query inside both breakdown functions — the categorized rollup
   *and* the separate "Uncategorized" subquery each of them runs — is restricted to accounts with
   `is_credit_card == false`. The restriction goes through `CashLens.Accounts.Scopes` (CL-33), not
   a fresh `where: a.is_credit_card == false`; since these queries only `join: c in assoc(t,
   :category)` and never join the account, the joining form `cash_accounts_only/1` is the relevant
   one.
2. **Expenses show the bill payment.** `get_month_category_breakdown/2` stops excluding the
   `cartao-de-credito` subtree, so payments made from a current account roll up into one
   `Cartão de Crédito` row. The `initial_value` and `transfer` subtrees stay excluded.
   **This must be done by changing which helper that one query calls, never by editing the
   shared helper.** `excluded_report_category_ids/0` (`lib/cash_lens/transactions.ex:754` at
   base commit `83a2532`) is read by three queries — `get_month_category_breakdown/2` (line
   511), `get_month_income_breakdown/2` (line 566) and `query_historical_category_totals/0`
   (line 720, the sole query behind `get_historical_category_summary/1`) — and the latter two
   must keep today's three-slug exclusion exactly. Only the call at line 511 changes: it moves
   to the **already existing** `excluded_cash_summary_category_ids/0` (same file, excludes the
   `initial_value` and `transfer` subtrees only), which is precisely the set this screen now
   needs and is already the set used by the cash-basis `get_historical_summary/1`. Editing
   `excluded_report_category_ids/0` in place would silently turn credit-card bill payments into
   a spend category in `get_historical_category_summary/1` — an out-of-scope regression, pinned
   against by the expected result below.
3. **Income keeps excluding `cartao-de-credito`.** This is deliberate and must not be
   "simplified" away. Today every positive transaction in that subtree (25 rows, R$ 231.263,49)
   sits on a card account and is already dropped by (1) — removing the category exclusion would
   look harmless while leaving nothing to stop a future current-account credit in that subtree
   from being reported as income.
4. **The parent-transaction exclusion must narrow.** `exclude_transactions_with_children/1` hides a
   transaction that other transactions point at via `parent_transaction_id`, on the premise that
   the children already carry the real categories. Once the children are invisible (they sit on
   card accounts), that premise fails: measured on the dev database, the 2026-06 bill payments
   (R$ 17.649,94) are exactly such parents and would silently vanish, leaving 52 rows /
   R$ 25.854,24 instead of the accepted 54 / R$ 43.504,18. So `get_month_category_breakdown/2`
   must exclude a transaction **only when at least one of its children is itself on a cash
   account** (i.e. still visible on this screen). `get_historical_category_summary/1` keeps the
   existing unrestricted helper — its universe did not change. There are 0 parents with cash-side
   children in the dev database today, so this rule is future-proofing and must be proven by unit
   test, not by dev data.
5. **The drill-down must match the row.** Expanding a category row calls
   `Transactions.list_all_transactions/1`, which has no account restriction, so a row whose total
   now counts only current accounts would still list the card-account transactions of the same
   category. The drill-down is restricted to cash accounts too (an opt-in filter key on
   `list_all_transactions/1`, applied only by this screen, so every other caller is untouched).
6. **The screen says which basis it is on.** The subtitle under "Fechamento do Mês" states the
   cash basis in Portuguese — card purchases appear through the bill payment, not one by one.
7. **Uncategorized behavior is preserved, not changed.** The categorized rollup uses an inner join
   on `:category`, so uncategorised transactions never appear there; they reach the screen only
   through the dedicated "Uncategorized" subquery. That split stays exactly as it is — only the
   account restriction is added to it.

### Layout is NOT changed by this task

This task changes **which transactions the figures count** (cash basis) and **adds the
`Cartão de Crédito` row to the expense breakdown**. It changes **nothing** about the layout of
`/months`. The following, all in `lib/cash_lens_web/live/month_live/month_panel.ex`, must survive
byte-equivalent apart from the one added subtitle:

- **Single-month view (`single_view/1`, lines 102-122).** The two category tables render as two
  successive `.single_table` calls — `"Receitas por Categoria"` then `"Gastos por Categoria"` —
  **stacked full width, one below the other**, inside a plain `<div class="space-y-6">`. There is
  no grid around them and none may be introduced. Do not put income and expenses in side-by-side
  columns.
- **Comparison view (`compare_view/1`, line 143).** The `grid grid-cols-1 lg:grid-cols-2` there is
  the **two-month** axis: `.compare_panel side="base"` (left) and `side="analysis"` (right). Each
  panel stacks its own income and expense tables vertically. Making income/expenses a column axis
  would collide with this one and force a nested or four-column grid. Do not touch this grid.
- The KPI card row (`grid-cols-1 sm:grid-cols-2 lg:grid-cols-4`), the period selectors, the
  drill-down row markup and the percentage bars are unchanged.

The only permitted markup change is the cash-basis subtitle of Expected Result 9. The accompanying
mockup `CL-31-mock.html` illustrates the *content* of the new figures and the new expense row; its
layout mirrors today's stacked arrangement and is not a redesign proposal.

### Files touched

- `lib/cash_lens/transactions.ex` — scope the four queries of the two month breakdown functions;
  point the categorized query of `get_month_category_breakdown/2` at the existing
  `excluded_cash_summary_category_ids/0` while leaving `excluded_report_category_ids/0` and its
  two other consumers (`get_month_income_breakdown/2`, `query_historical_category_totals/0`)
  byte-for-byte as at `83a2532`; add the cash-children variant of the
  parent exclusion used solely by `get_month_category_breakdown/2`; add the opt-in cash-accounts
  filter key to `list_all_transactions/1`; update both function docstrings.
- `lib/cash_lens_web/live/month_live/show.ex` — pass the new filter from `load_row_transactions/2`;
  replace the `total_of/1` comment block, which currently documents the opposite universe
  ("every account, credit cards included").
- `lib/cash_lens_web/live/month_live/month_panel.ex` or `show.ex` header — the cash-basis subtitle.
- `test/cash_lens/transactions_test.exs` — the two tests asserting the old parent/credit-card
  behavior now assert the new one; new tests for the account scope, the income exclusion, the
  cash-children rule, the uncategorized subqueries, and a regression test proving
  `get_historical_category_summary/1` still drops `cartao-de-credito` spending.
- `test/cash_lens_web/live/month_live_test.exs` — drill-down scoping and the subtitle.

### Test criteria

Fixture-level unit tests (a cash account and a card account, one category each) prove: card-account
transactions are absent from both breakdowns; a `cartao-de-credito` payment on a cash account
appears in the expense breakdown whether or not it has card-side children; a cash-account
transaction whose child is also on a cash account stays hidden; a positive `cartao-de-credito`
transaction on a **cash** account is still absent from the income breakdown; uncategorised
card-account transactions no longer produce an "Uncategorized" row on either side; and a LiveView
test proving the expanded row lists no card-account transaction.

Database access: `./run` is live and is the only thing publishing Postgres on `localhost:5432`
(docker-compose.yml never publishes it). Run the suite on the host —
`DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=test mix test`. Never start the compose stack
while `./run` is live, and never stop `./run` in order to test: that leaves no reachable database.

`mix quality_check` is not achievable here (~23 pre-existing credo findings in untouched files);
the bar is no new credo finding in a touched file against a baseline recorded before the change.
Pre-existing, unrelated failures:
`test/cash_lens_web/live/transaction_live/index_coverage_test.exs:170` (intermittent Postgrex
`query_canceled`) and `test/cash_lens_web/live/forecast_live_test.exs:554`.
`lib/cash_lens/pluggy/live_preview.ex` and `lib/cash_lens/transactions/category_suggester.ex` carry
unrelated uncommitted work and must not be staged, modified, reverted or formatted.

![Mockup](CL-31-mock.html)

## Expected Results

- [ ] 1. Cash accounts only. In `lib/cash_lens/transactions.ex`, all four queries of
      `get_month_category_breakdown/2` and `get_month_income_breakdown/2` (the categorized
      rollup and the separate "Uncategorized" subquery of each) are restricted to accounts with
      `is_credit_card == false` via a `CashLens.Accounts.Scopes` function, not an inline
      `where: a.is_credit_card == false`. A test in `test/cash_lens/transactions_test.exs`
      creates one categorized negative and one categorized positive transaction on a
      credit-card account and asserts neither appears in the respective breakdown.
- [ ] 2. Expenses include the credit-card bill payment. A test creates a negative transaction
      in the `cartao-de-credito` category on a non credit-card account and asserts
      `get_month_category_breakdown/2` returns a row for it; transactions in the
      `initial_value` and `transfer` subtrees on the same account are asserted absent.
- [ ] 3. Income still excludes `cartao-de-credito`. A test creates a POSITIVE transaction in
      the `cartao-de-credito` category on a NON credit-card account and asserts it is absent
      from `get_month_income_breakdown/2`.
- [ ] 4. `get_historical_category_summary/1` still excludes `cartao-de-credito` spending. A test
      in `test/cash_lens/transactions_test.exs` creates a single negative transaction in the
      `cartao-de-credito` category on a NON credit-card account with NO child transactions
      pointing at it (no other transaction has that transaction's id as its
      `parent_transaction_id`), and asserts no row of that category or any of its children
      appears in `Transactions.get_historical_category_summary()`. This test fails if the
      `cartao-de-credito` slug is dropped from the helper shared with
      `get_month_income_breakdown/2` and `query_historical_category_totals/0` instead of only
      `get_month_category_breakdown/2` being pointed at a different helper.
- [ ] 5. Parent exclusion narrowed. A test proves a cash-account transaction whose only children
      sit on credit-card accounts IS included in `get_month_category_breakdown/2`, and a
      cash-account transaction with at least one child on a cash account is NOT included.
- [ ] 6. Drill-down matches the row. A LiveView test on `/months/:year/:month` expands a
      category row and asserts the listed transactions include the cash-account transaction of
      that category and exclude a credit-card-account transaction of the same category.
      `Transactions.list_all_transactions/1` gains an opt-in filter key for this; a test asserts
      a call without that key still returns credit-card-account transactions.
- [ ] 7. Dev-database values, verified in `iex -S mix` against the running dev database:
      `Transactions.get_month_category_breakdown(2026, 9)` totals R$ 40.006,17 and
      `get_month_income_breakdown(2026, 9)` totals R$ 37.167,83, matching the 2026-09 entry of
      `Transactions.get_historical_summary/1`; `get_month_category_breakdown(2026, 6)` totals
      R$ 43.504,18 and contains a `Cartão de Crédito` row of R$ 17.649,94, and
      `get_month_income_breakdown(2026, 6)` totals R$ 54.713,34. The same figures show on
      `/months/2026/9` and `/months/2026/6`.
- [ ] 8. Dashboard untouched. `git diff 83a2532 -- lib/cash_lens/transactions.ex` shows no change
      to the bodies of `get_historical_summary/1`, `get_monthly_summary/2`,
      `get_historical_category_summary/1`, `query_historical_category_totals/0` or
      `excluded_report_category_ids/0` (docstring/comment edits aside), and
      `get_month_income_breakdown/2` still calls `excluded_report_category_ids/0`. The dashboard
      figures at `/` are unchanged from base commit `83a2532`.
- [ ] 9. Screen states its basis. `/months/:year/:month` shows a Portuguese subtitle under
      "Fechamento do Mês" explaining that the view is cash basis and that card purchases appear
      through the bill payment; a LiveView test asserts the text is rendered.
- [ ] 10. Suite and style. `DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=test mix test`
      passes except the two known-unrelated failures
      `test/cash_lens_web/live/transaction_live/index_coverage_test.exs:170` and
      `test/cash_lens_web/live/forecast_live_test.exs:554`. `mix format --check-formatted`
      passes. `mix credo` reports no finding in a file touched by this task that was not already
      reported at base commit `83a2532`. `git status` shows
      `lib/cash_lens/pluggy/live_preview.ex` and
      `lib/cash_lens/transactions/category_suggester.ex` still modified-but-unstaged and not
      altered by this task.

## Out of Scope

Restoring a per-category view of card spending; changing the dashboard; changing
`get_historical_category_summary/1`; the reimbursement-pair filter (CL-32).
