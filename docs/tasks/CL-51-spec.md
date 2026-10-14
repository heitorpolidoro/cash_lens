# CL-51 — Scope all queries by the current user

## Scope
Part 3 of the CL-20 split. Depends on CL-50 (`user_id` NOT NULL FK, `belongs_to :user` on the 12 domain tables). After this task, no code path can read or write a row of the 12 domain tables without naming its owner, and one user can never see or change another user's rows.

In scope: the public API of the `Accounts`, `Accounting`, `Categories`, `CreditCards`, `Forecast`, `Imports`, `Installments` and `Transactions` contexts and their helper modules (`Accounting.BalanceAdjuster`, `CreditCards.Matcher`, `Transactions.AutoCategorizer`, `CategorySuggester`, `TransferMatcher`, `TransferRuleApplier`, `InstallmentDetector`, `Parsers.Ingestor`, `Parsers.DirectoryImporter`); every LiveView and JSON controller; the Oban workers; every mix task; `AdminDatabaseLive`; and removal of the interim operator fallback from CL-50.

Not in scope: per-user uniqueness (see Out of Scope), row-level security, `users`/audit/health/settings code, admin UI redesign.

## Approach

### Behavior
- **Convention.** Every public function in the listed contexts that reads or writes domain rows takes the owner as its **first argument**, a `%CashLens.Users.User{}`. Context code reduces it to `user.id` and filters with one shared query helper, exactly `CashLens.Ownership.scope(queryable, %CashLens.Users.User{} = user)` (arity 2; returns the queryable with `where: x.user_id == ^user.id`; it does not exist yet in `ownership.ex` and is added by this task), so no module hand-writes the predicate. Foreign-key ownership is checked by one shared changeset helper, exactly `CashLens.Ownership.validate_owned(changeset, field, schema)` (arity 3): it reads the changeset's `user_id`, and when `field` has a change, looks the id up with `scope/2` on `schema` and adds a changeset error on `field` if no owned row exists. Every changeset with a caller-supplied foreign key calls it for each such field. Pure functions that touch no rows (formatters, parsers, `Transaction.dedup_key/1`, fingerprint math) stay unchanged. Internal arity changes are expected to ripple through callers and tests.
- **Reads** (`list_*`, `get_*`, summaries, search, suggestions, forecast/balance queries, counts, exists checks) filter every table in the query by `user_id`, including joins and subqueries (a transaction of A joined to a category of B must not match). `get_*!` raises `Ecto.NoResultsError` for another user's id; `get_*` returns `nil`.
- **Writes** (`update_*`, `delete_*`, bulk `update_all`/`delete_all`, link/unlink, reimbursement, transfer and installment operations) follow one signature shape: `update_*(user, %Schema{} = record, attrs)` and `delete_*(user, %Schema{} = record)`, with the user first as in the Convention. The function re-fetches the record by `record.id` through `Ownership.scope/2`, so only rows owned by that user are operated on; no `update_*`/`delete_*` accepts a bare id. Bulk and link-style operations take `(user, ids_or_args...)`. A record owned by another user yields `{:error, :not_found}` (or raises `Ecto.NoResultsError` for bang variants), never a mutation. Creates (`create_*`, `Repo.insert`, `insert_all`) set `user_id` from the user argument. Foreign keys supplied by the caller (`account_id`, `category_id`, `parent_id`, `payment_transaction_id`, `installment_group_id`, ...) must point at rows owned by the same user; otherwise the changeset errors (validation, not a DB error).
- **Repo fallback removed.** `CashLens.Repo`'s `insert/insert!` override and `Ownership.assign/1`, `put_user_id/1`, `current_user_id!/0`, and the `:auto_create_owner` test setting are deleted. `Ownership.domain_schemas/0` stays (used by `Privacy`). Operator resolution (`CASH_LENS_OPERATOR_EMAIL`, only-user) survives solely as a helper for mix tasks and seeds (`Ownership.operator_user!/0`), and is never called from the web layer or contexts.
- **Web layer.** LiveViews read `socket.assigns.current_user` (already set by `UserAuth.on_mount/4`) and pass it into every context call, including in `handle_event`, `handle_info`, PubSub/async callbacks, and `handle_params`. JSON controllers read `conn.assigns.current_user` (set by `require_enabled_user_api`). A request for another user's id: LiveViews (`AccountLive.Show`, `CategoryLive.Show`, `TransactionLive.Index` show/edit, `RecurringItemLive.Index` edit, `AccountLive.Index` edit) redirect with a flash to the list route, never rendering data; API controllers answer `404` through the existing fallback for `Ecto.NoResultsError`/`{:error, :not_found}`. Event params carrying ids (delete, link, ignore, bulk selections) are resolved through the scoped getters, so a forged id from another user is a no-op with an error flash.
- **`AdminDatabaseLive`** keeps working as a table browser but, for the 12 domain tables, shows only rows with `user_id == current_user.id`; other tables behave as today.
- **Workers.** `RecalculateBalanceWorker` and `SyncRecurringWorker` args gain `"user_id"`; `perform/1` loads the user, scopes all queries, and fails (discard, no retry) when the user no longer exists. Every `Oban` enqueue site passes `user_id`. Jobs already enqueued without `user_id` are discarded with a log line, since balances can be recomputed.
- **Import pipelines.** `Ingestor`, `DirectoryImporter`, `Imports` and the matchers take the user, create `imported_files`/`import_runs`/`transactions`/`statements`/`balances` with that `user_id`, and resolve accounts, categories, rules and duplicates only among that user's rows. The `ImportLive` upload flow passes `current_user`.
- **Mix tasks** (`cash_lens.import`, `backfill_statements`, `migrate_ourocard_txt`, `recompute_competencia`, `reconcile_pending_statements`, `migrate_credit_card_transfers`) take the target explicitly via `--user <email>` (required when more than one user exists; with exactly one user it may be omitted; otherwise the task aborts with a usage message before touching data) and pass the resolved user down. `priv/repo/seeds.exs` does the same.
- **Raw SQL.** Any `Repo.query`/fragment/`insert_all` touching domain tables gets `user_id` in its WHERE or row maps. `Privacy` already filters by user; leave it, but confirm it still compiles against the new signatures.
- **Guard check.** One mechanism: an ExUnit test, `test/cash_lens/user_scoping_audit_test.exs`, reads every `.ex` file under `lib/` as text, splits it into function blocks at each `def`/`defp`, and fails for any block that matches the regex `Repo\.(all|one|get|get!|get_by|get_by!|update_all|delete_all|aggregate|exists\?|stream|insert_all)\(` or `\bfrom\(?\s*\w+\s+in\s+` and contains neither `Ownership.scope(` nor `user_id`. The one allow-list is the module attribute `@allow_list` at the top of that same test file: exactly the paths `lib/cash_lens/users.ex`, `audit.ex`, `health.ex`, `privacy.ex`, `ownership.ex` and `application.ex` under `lib/cash_lens/`, each with a comment giving the reason. No other allow-list exists; adding an entry requires editing that attribute.

### Implementation sequence (one PR, committed in this order so each step compiles and `mix test` stays green)
1. Foundation: `Ownership.scope/2`, `Ownership.validate_owned/3`, operator helper, test fixtures take a `user` (default: fresh user from the CL-49 users fixture), shared `cross_tenant` test helper. Remove the Repo override last, in step 9.
2. `Accounts` and `Categories` (leaf contexts), their LiveViews, API controllers.
3. `Accounting` (+ `BalanceAdjuster`), `RecalculateBalanceWorker`, balance LiveViews and `BalanceController`.
4. `Transactions` core (CRUD, filters, summaries, bulk ignore, transfer rules, rejected pairs, matcher, applier, auto-categorizer, suggester), transaction/month/reimbursement/transfer/automation LiveViews and `TransactionController`.
5. `Installments` (+ detector) and `InstallmentLive`, `InstallmentGroupController`.
6. `CreditCards` (+ `Matcher`) and `CreditCardStatementLive`.
7. `Forecast`, `RecurringItemLive`, `ForecastLive`, `SyncRecurringWorker`, dashboard `PageController`/home data.
8. `Imports`, `Parsers.Ingestor`, `DirectoryImporter`, `ImportLive`, mix tasks, seeds, `AdminDatabaseLive`.
9. Remove Repo override and `Ownership` fallback; add the scoping audit test; update `AGENTS.md` (ownership section, `Ownership` description, conventions: "first argument is the user").

### Files touched
- `lib/cash_lens/{accounts,accounting,categories,credit_cards,forecast,imports,installments,transactions}.ex` and subfolders listed in Scope: add the user first argument, scope all queries, set `user_id` on creates.
- `lib/cash_lens/ownership.ex`, `lib/cash_lens/repo.ex`: `scope/2` and `validate_owned/3` added; fallback removed.
- `lib/cash_lens/workers/*.ex`: `user_id` arg.
- `lib/cash_lens/parsers/{ingestor,directory_importer}.ex`: user threaded through.
- `lib/cash_lens_web/live/**`, `lib/cash_lens_web/controllers/api/*.ex`, `page_controller.ex`, `admin_database_live.ex`: pass `current_user`, handle not-found.
- `lib/mix/tasks/*.ex`, `priv/repo/seeds.exs`: `--user` option.
- `test/support/fixtures/*.ex`, `config/test.exs`: user-aware fixtures, drop `:auto_create_owner`.
- Existing tests under `test/`: updated to the new signatures.
- New tests listed below; `AGENTS.md` doc update.

### Test criteria
- One cross-tenant test per context (`test/cash_lens/<context>_tenancy_test.exs`, using the shared helper): with user A owning rows and user B calling the same functions, B's `list_*` returns `[]` (or none of A's rows), `get_*` returns nil / `get_*!` raises, `update_*` and `delete_*` return not-found and A's row is unchanged in the DB. Contexts: accounts, accounting, categories, credit_cards, forecast, imports, installments, transactions. Also: B cannot reference A's account/category as a foreign key on create.
- LiveView/controller tests: logged in as B, visiting each id-bearing route for A's record (`/accounts/:id`, `/accounts/:id/edit`, `/categories/:id`, `/transactions/:id`, `/transactions/:id/edit`, `/recurring_items/:id/edit`) redirects with a flash and the page never contains A's data; `GET/PUT/DELETE /api/<resource>/:id` for A's record returns 404; list endpoints and list LiveViews show only B's rows; a forged event id from A is rejected.
- Worker tests: job without a valid `user_id` is discarded; a job for A never writes B's balances.
- Import test: importing the same file as A and as B yields rows owned by each, each with its own `imported_files`/`import_runs` rows, and no cross-linking of transfers.
- Mix tasks: run with `--user` creates rows owned by that user; with several users and no `--user` aborts without writes.
- `user_scoping_audit_test.exs` passes; full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] Public functions of the accounting, categories, credit_cards, forecast, imports, installments, transactions (and accounts) contexts take the user as first argument and filter by `user_id`, enforced by `user_scoping_audit_test.exs`.
- [ ] Every LiveView, controller and `AdminDatabaseLive` passes `current_user` into context calls; no unscoped domain query remains outside the `@allow_list` in `user_scoping_audit_test.exs`.
- [ ] `RecalculateBalanceWorker`, `SyncRecurringWorker`, the import pipeline and all mix tasks take an explicit user (`user_id` arg or `--user`) and set `user_id` on every record created.
- [ ] Each context's `*_tenancy_test.exs` proves user B gets empty results, not-found, or an unchanged record when listing, getting, updating or deleting user A's rows.
- [ ] Requesting another user's record by id returns `404` from `/api/*` and redirects with a flash from the LiveView routes, never rendering the data.
- [ ] Inserting a domain row without a `user_id` fails instead of being assigned an owner, since `CashLens.Repo` has no insert override and `Ownership.assign/1` is gone.

## Out of Scope
- Per-user uniqueness: unique indexes (`transactions.fingerprint`, `categories.slug`, `imported_files.path`, `bulk_ignore_patterns.pattern`, `balances` account/month) stay global until the next CL-20 part. Note that until then, user B importing a transaction identical to A's may hit a unique-index conflict; the test for imports must use distinct data per user.
- Row-level security, user deletion flow, sharing data between users, Oban ownership beyond the two `user_id` args.
