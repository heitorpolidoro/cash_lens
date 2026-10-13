# CL-57 — Scope Accounting and balance recalculation by the current user

## Scope
Part 3 of the CL-51 split (`docs/tasks/CL-51-spec.md`, step 3). Builds on CL-55 (`Ownership.scope/2`, `cross_tenant`) and CL-56 (`Accounts`/`Categories` take the user first; transitional `Ownership.current_user!/0` shim). After this task `Accounting`, `Accounting.BalanceAdjuster`, `RecalculateBalanceWorker`, `BalanceLive`, `MonthLive` and `Api.BalanceController` name the owner on every call and never read or change another user's rows.

Not in scope: scoping `Transactions`, `Installments`, `Forecast`, `CreditCards`, `Imports`, `Ingestor` (CL-51 parts 4-8) — they only get mechanical call-site updates here; `SyncRecurringWorker`; removal of the Repo insert override, `Ownership.assign/1` or `current_user!/0`; the scoping audit test; per-user uniqueness of `balances` (account/month stays global).

## Approach

### Behavior
- **Signatures.** Every public `Accounting` function that touches rows takes `%CashLens.Users.User{}` first: `calculate_monthly_balance`, `get_latest_balance_for_account`, `get_oldest_balance_for_account`, `list_balances`, `rebuild_account_balances`, `recalculate_all_balances`, `list_latest_balances`, `get_historical_balances`, `get_balance!`, `create_balance`, `update_balance`, `delete_balance`, `heal_active_balances`, the healing helper used by the dashboard, and `__test_calculate_from_point`. `change_balance/2` stays pure. `BalanceAdjuster.adjust_final_balance` and `current_final_balance` also take the user first, then the existing args. Private helpers receive the user and pass it down.
- **Filtering.** Every query in these modules goes through `Ownership.scope/2` (no hand-written `user_id` predicate), on each table of a join or subquery: balances, the transactions summed for a month (a transaction of A joined to a category or account of B must not count), accounts, and the preloaded `:account`. `list_latest_balances(user, accounts: ...)` ignores listed accounts the user does not own.
- **Reads.** `get_balance!(user, id)` raises `Ecto.NoResultsError` for another user's id. The "latest/oldest balance for account" getters return `nil` when the account belongs to another user. List functions return only the user's rows.
- **Writes.** `calculate_monthly_balance(user, account_id, y, m)` and `rebuild_account_balances(user, account_id)` return `{:error, :not_found}` and write nothing when the account is not the user's. Created balances get `user_id` from the user; a `"user_id"` in attrs is ignored. `update_balance(user, balance, attrs)` and `delete_balance(user, balance)` re-fetch by `balance.id` via `scope/2` and return `{:error, :not_found}` for another user's row, leaving it unchanged. `Balance.changeset` calls `Ownership.validate_owned(:account_id, Account)`. `BalanceAdjuster` resolves the account with the CL-56 `Accounts.get_account!(user, ...)` / `Accounts.update_account(user, ...)`; a foreign `account_id` yields `{:error, :not_found}`. The income transaction it creates still uses the current `Transactions` signature (converted in the next part), with the user's `user_id`.
- **Worker.** `RecalculateBalanceWorker` args gain `"user_id"`. `perform/1` loads the user; when `user_id` is missing or the user no longer exists it logs and returns `{:discard, reason}` (no retry) without touching data. All its queries, including the "next period balance exists" check, are scoped to that user, and the chained next-period job carries the same `"user_id"`. It stops calling `Ownership.pin_operator!/0` and pins the loaded user instead (`Repo.with_user/2`), which CL-53 row-level security needs. Oban uniqueness must keep `user_id` in its key (default keys cover all args; verify). Jobs queued before this change lack `user_id` and are discarded by the missing-arg clause. Today the only enqueue site is the worker's own `enqueue_job/3`; it passes `user_id`, and so must any other site that `grep RecalculateBalanceWorker lib` finds.
- **Web.** `BalanceLive.Index`, `MonthLive.Show` (and `MonthLive.MonthPanel` if it calls the context) use `socket.assigns.current_user` in `mount`, `handle_params`, `handle_event` and `handle_info`. The balance adjustment event resolves its account through the scoped getter, so a forged `account_id` of another user is a no-op with an error flash. `Api.BalanceController` passes `conn.assigns.current_user`; `GET /api/balances/:id` for another user's balance answers `404` through the existing rescue; `index` returns only the user's balances (a foreign `account_id` filter gives an empty list).
- **Callers outside this task** keep compiling and passing: `Transactions` (rebuild calls), `Installments`, `Parsers.Ingestor`, `Forecast`, `TransactionLive.Index`, `TransferLinkComponent`, `PageController`, `AccountLive.{Index,FormComponent}`, `Accounts.delete_account`. Web-layer callers pass `current_user` from assigns/conn; contexts without a user use `Ownership.current_user!/0` with the comment `# TRANSITIONAL: removed when CL-51 converts the caller`. No behavior change there.

### Files touched
- `lib/cash_lens/accounting.ex`, `lib/cash_lens/accounting/balance_adjuster.ex`: user first argument, `scope/2` on every query, owner set on create, `{:error, :not_found}`.
- `lib/cash_lens/accounting/balance.ex`: `validate_owned(:account_id, Account)`.
- `lib/cash_lens/workers/recalculate_balance_worker.ex`: `user_id` arg, discard clause, scoped queries, user pin, `user_id` in the chained job.
- `lib/cash_lens_web/live/balance_live/index.ex`, `lib/cash_lens_web/live/month_live/{show,month_panel}.ex`, `lib/cash_lens_web/controllers/api/balance_controller.ex`: pass the user.
- Mechanical call-site updates (user or shim) in the files listed under "Callers outside this task" and any other file the compiler flags.
- Existing tests and `test/support/fixtures/accounting_fixtures.ex` updated to the new signatures.
- New: `test/cash_lens/accounting_tenancy_test.exs`, `test/cash_lens_web/controllers/api/balance_controller_tenancy_test.exs`; cases appended to `test/cash_lens/workers/recalculate_balance_worker_test.exs`, `test/cash_lens_web/live/balance_live_test.exs` and the month live test.

### Test criteria
- Accounting tenancy (via `cross_tenant`; A owns accounts, transactions and balances): for B, `list_balances`, `list_latest_balances`, `get_historical_balances` are `[]`; `get_balance!` raises `Ecto.NoResultsError`; latest/oldest getters return `nil`; `update_balance`/`delete_balance` return `{:error, :not_found}`; `calculate_monthly_balance` and `rebuild_account_balances` with A's account id return `{:error, :not_found}`; `BalanceAdjuster.adjust_final_balance(b, a_account_id, ...)` returns `{:error, :not_found}`; creating a balance on A's account as B gives a changeset error on `account_id`. A's balances and account balance are unchanged in the DB. A monthly total for B never includes A's transactions even when both have data in the same year/month.
- Worker: `perform` without `"user_id"`, and with a deleted user's id, returns `{:discard, _}` and writes nothing; a job for A leaves B's balances untouched (B has balances for the same months) and the chained job it enqueues has A's `user_id`.
- API, logged in as B: `GET /api/balances/:id` for A's balance returns `404` without A's data; index lists only B's balances.
- LiveView, logged in as B: balance and month pages show only B's rows and never A's account names; a forged adjust event carrying A's account id is a no-op with an error flash and A's account balance is unchanged.
- Full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] Public functions of `Accounting` and `Accounting.BalanceAdjuster` take the user first and filter every table, joins included, through `Ownership.scope/2`.
- [ ] `accounting_tenancy_test.exs` proves user B gets empty lists, `nil`, `Ecto.NoResultsError` or `{:error, :not_found}` for user A's balances and accounts, and A's rows stay unchanged.
- [ ] `RecalculateBalanceWorker.perform/1` returns `{:discard, _}` when `user_id` is missing or the user no longer exists, proven by a worker test.
- [ ] A `RecalculateBalanceWorker` job for user A never writes user B's balances, and the chained next-period job carries A's `user_id`, proven by a worker test.
- [ ] Every enqueue site of `RecalculateBalanceWorker` passes `user_id` (today only the worker's own `enqueue_job/3`).
- [ ] `BalanceLive` and `MonthLive` pass `current_user` into context calls, and `GET /api/balances/:id` for another user's balance returns `404`, with `mix test` and `mix precommit` passing.

## Out of Scope
- Scoping Transactions, Installments, Forecast, CreditCards, Imports, `SyncRecurringWorker`, mix tasks (later CL-51 parts).
- Removing the Repo override, `Ownership.assign/1`, `current_user!/0`.
- Per-user uniqueness of balances.
