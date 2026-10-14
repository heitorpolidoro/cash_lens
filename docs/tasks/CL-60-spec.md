# CL-60 — Scope Forecast and recurring items by the current user

## Scope
Part 6 of the CL-51 split (`docs/tasks/CL-51-spec.md`, step 7). Builds on CL-55..CL-59 and reuses their conventions: user-first signatures, `Ownership.scope/2` on every table of a query (joins and subqueries included), `{:error, :not_found}` on foreign writes, `Ecto.NoResultsError` on foreign `get_*!`, `Ownership.validate_owned/3` for caller-supplied keys, and the transitional `Ownership.current_user!/0` shim (marked `# TRANSITIONAL: removed when CL-51 converts the caller`) for callers not converted here.

In scope: `CashLens.Forecast`, `Forecast.RecurringItem`, `Workers.SyncRecurringWorker`, `RecurringItemLive.Index`, `ForecastLive.Index`, the dashboard `PageController`, and the one enqueue site in `Parsers.Ingestor`.

Not in scope: the rest of `Ingestor`/`DirectoryImporter`, `Imports`, mix tasks, `AdminDatabaseLive`, the scoping audit test, removal of the Repo insert override / `Ownership.assign/1` / `current_user!/0`, per-user uniqueness. No UI redesign, no mock.

## Approach

### Behavior
- **Signatures.** Every public `Forecast` function that touches rows takes `%CashLens.Users.User{}` first: `create_recurring_item`, `suggest_for_category`, `list_recurring_items`, `list_recurring_items_with_category`, `list_commitment_rows`, `get_recurring_item!`, `delete_recurring_item`, `sync_all`, `deactivate_superseded_items`, `resync_item`, `manual_update`, `toggle_active`, `set_as_salary`, `unset_salary`, `project`, `variable_baseline_rate`, `monthly_volatility`, `list_categories_without_recurring_item`, `overdue_occurrences`, `card_occurrences`, `commitment_occurrences`; private helpers they use (`window_rows`, `fully_grouped_category?`, ...) receive the user too. Pure functions over an in-memory projection stay unchanged (`balance_on`, `occurrences_within`, `ruler_occurrences`, `upcoming_bills`, `daily_balances`, `minimum_point`, `final_balance`, `trough`, `projected_change_percent`, `next_income_date`, `next_occurrence_date`, `change_recurring_item`).
- **Filtering.** Every query in `Forecast` (recurring items, categories, transactions, accounts, installment groups, statements, and its internal calls into `Installments`/`CreditCards` from CL-59) goes through `Ownership.scope/2` on each table. Starting balance, salary lookup, baseline rate and volatility use only the user's data. A user with no data gets empty lists and a zero-state projection.
- **Writes.** `manual_update`, `toggle_active`, `set_as_salary`, `unset_salary`, `resync_item` and `delete_recurring_item` re-fetch by `record.id` through `scope/2` and return `{:error, :not_found}` for another user's row, leaving it unchanged. `set_as_salary` clears the previous salary flag only among the user's own items. `sync_all(user)` and `deactivate_superseded_items(user)` read and write only that user's rows. Creates set `user_id` from the user; a `"user_id"` in attrs is ignored.
- **Foreign keys.** `RecurringItem.changeset` calls `Ownership.validate_owned/3` for `:category_id` (and any other account/category key it casts); a foreign id yields a changeset error on that field, not a DB error.
- **Worker.** `SyncRecurringWorker.enqueue(user_id)` puts `user_id` in the job args; `perform/1` requires `"user_id"` in args. A missing `user_id`, or a user that no longer exists, returns `{:discard, reason}` (no retry, no writes). Otherwise it loads the user, runs `Forecast.sync_all(user)` and broadcasts the result. Uniqueness is keyed on `user_id` so a batch import by A is never collapsed into B's job. A job for A never writes B's rows. The flash broadcast is addressed to that user only.
- **Enqueue sites.** `Ingestor.maybe_sync_recurring` passes the owning user's id (via the TRANSITIONAL `Ownership.current_user!/0` shim until CL-51 converts the importer). A grep for `SyncRecurringWorker.enqueue` finds no zero-arity call.
- **RecurringItemLive.** Uses `socket.assigns.current_user` in `mount`, `handle_params`, events and `handle_info`. `/recurring_items/:id/edit` with another user's id redirects to `/recurring_items` with an error flash and renders none of the item's data (no `Ecto.NoResultsError` crash). A forged foreign id in toggle/resync/delete/save events gives an error flash and changes no row.
- **ForecastLive.** Passes `current_user` into every `Forecast` call (salary toggle, resync, sync button, create/update, chart data); a forged foreign id gives an error flash and changes nothing.
- **PageController.** Passes `conn.assigns.current_user` to `Forecast.project` and related calls so the dashboard forecast and upcoming bills cover only the logged-in user. The dashboard query budget test keeps passing.
- **Other callers** (`BankruptcyCard`, `Accounts.Scopes` docs, anything the compiler flags) get mechanical updates only.

### Files touched
- `lib/cash_lens/forecast.ex`: user first, `scope/2` everywhere, `{:error, :not_found}`, owner on creates.
- `lib/cash_lens/forecast/recurring_item.ex`: `validate_owned` on foreign keys.
- `lib/cash_lens/workers/sync_recurring_worker.ex`: `user_id` arg, discard rules, per-user uniqueness.
- `lib/cash_lens/parsers/ingestor.ex`: pass user id to `enqueue` (shim marker).
- `lib/cash_lens_web/live/recurring_item_live/index.ex`, `lib/cash_lens_web/live/forecast_live/index.ex`, `lib/cash_lens_web/controllers/page_controller.ex`, `lib/cash_lens_web/components/bankruptcy_card.ex` (if flagged): pass the user, not-found handling.
- Existing tests and `test/support/fixtures/forecast_fixtures.ex` updated to the new signatures (`forecast_test.exs`, `forecast_scope_guard_test.exs`, `sync_recurring_worker_test.exs`, `recurring_sync_flash_test.exs`, `recurring_item_live_test.exs`, `forecast_live_test.exs`, `page_controller_test.exs`, `dashboard_query_budget_test.exs`, `ingestor_test.exs`).
- New: `test/cash_lens/forecast_tenancy_test.exs`; cases appended to `sync_recurring_worker_test.exs`, `recurring_item_live_test.exs`, `forecast_live_test.exs`, `page_controller_test.exs`.

### Test criteria
- Context tenancy (via `cross_tenant`; A owns recurring items, categories, accounts, transactions): for B every list, projection, baseline, volatility and overdue function returns empty/zero-state; `get_recurring_item!` raises `Ecto.NoResultsError`; update/toggle/salary/resync/delete return `{:error, :not_found}`; A's rows are unchanged in the DB; `sync_all(B)` leaves A's items untouched; B creating an item with A's `category_id` gets a changeset error and inserts nothing.
- Worker: a job with no `user_id` or an unknown one returns `{:discard, _}` and writes nothing; a job for A leaves B's rows unchanged; `enqueue(user.id)` yields a job whose args contain that id; jobs for A and B are not collapsed by `unique`.
- LiveView, logged in as B: `/recurring_items` and `/forecast` list only B's items; `/recurring_items/:id/edit` for A's id redirects with a flash and the HTML contains none of A's data; a forged foreign id event changes nothing.
- Dashboard, logged in as B: forecast and upcoming bills never include A's items or balances.
- Full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] Public `Forecast` functions take the user first and filter every table through `Ownership.scope/2`.
- [ ] `forecast_tenancy_test.exs` proves user B gets empty results, `Ecto.NoResultsError` or `{:error, :not_found}` for user A's recurring items and A's rows are unchanged.
- [ ] `SyncRecurringWorker.perform/1` discards a job with a missing `user_id` or a deleted user, and a job for user A never writes user B's rows (worker tests).
- [ ] Every `SyncRecurringWorker` enqueue site passes `user_id`, and the job args contain it.
- [ ] `/recurring_items/:id/edit` for another user's record redirects with an error flash and renders none of its data.
- [ ] `ForecastLive` and the dashboard `PageController` pass `current_user` and show only the logged-in user's data.

## Out of Scope
- The rest of Ingestor, DirectoryImporter, Imports, mix tasks, `AdminDatabaseLive` (later CL-51 parts).
- Removing the Repo override, `Ownership.assign/1`, `current_user!/0`; the scoping audit test.
- Per-user uniqueness constraints.
