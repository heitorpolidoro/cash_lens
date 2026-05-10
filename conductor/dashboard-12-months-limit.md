# Implementation Plan: Limit Dashboard Chart to 12 Months

## Objective
Limit the data displayed on the dashboard chart (historical balances, historical summary, and category summary) to the last 12 months.

## Key Files & Context
- `lib/cash_lens_web/controllers/page_controller.ex`: Orchestrates the dashboard data fetching.
- `lib/cash_lens/accounting.ex`: Contains `get_historical_balances/0`.
- `lib/cash_lens/transactions.ex`: Contains `get_historical_summary/0` and `get_historical_category_summary/0`.

## Implementation Steps

### 1. Update Accounting Context
- Modify `Accounting.get_historical_balances/0` to `get_historical_balances(opts \\ [])`.
- If `limit` is provided in `opts`:
    - Order by `desc: year, desc: month`.
    - Apply `limit`.
    - Wrap in a subquery or sort the results in memory to restore `asc` order (expected by the chart).

### 2. Update Transactions Context
- Modify `Transactions.get_historical_summary/0` to `get_historical_summary(opts \\ [])`.
- If `limit` is provided in `opts`:
    - Order is already `desc`.
    - Apply `limit`.
- Modify `Transactions.get_historical_category_summary/0` to `get_historical_category_summary(opts \\ [])`.
- If `limit` is provided in `opts`:
    - Slice the final list after `sort_by` to take only the last `n` months.

### 3. Update Page Controller
- Update `PageController.home/2` to call the above functions with `limit: 12`.

## Verification & Testing
- Create a new test `test/cash_lens_web/controllers/dashboard_limit_test.exs`.
- Seed data for 15 months.
- Assert that `chart_data`, `fixed_data`, and `variable_data` assigns only contain 12 months.
- Verify that the months returned are indeed the most recent 12 months.
- Run `mix test` to ensure no regressions.
