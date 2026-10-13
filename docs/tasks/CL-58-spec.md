# CL-58 — Scope Transactions core by the current user

## Scope
Part 4 of the CL-51 split (`docs/tasks/CL-51-spec.md`, step 4). Builds on CL-55 (`Ownership.scope/2`, `Ownership.validate_owned/3`, `cross_tenant` test helper), CL-56 (`Accounts`/`Categories` take the user first) and CL-57 (conventions: user-first signatures, `scope/2` on every table of a query, `{:error, :not_found}` on foreign writes, transitional `Ownership.current_user!/0` shim). After this task `Transactions` and its helpers name the owner on every call and never read or change another user's rows.

In scope: `CashLens.Transactions` (CRUD, filters, summaries, breakdowns, historical summaries, bulk ignore patterns, transfer rules, rejected reimbursement pairs, transfer/reimbursement link and suggestion functions, mirror creation, `statement_health`, `count_pending_transactions`, `delete_all_transactions`, `reapply_*`), `TransferMatcher`, `TransferRuleApplier`, `AutoCategorizer`, `CategorySuggester`, `TransactionLive.{Index,FormComponent,ReimbursementLinkComponent,TransferLinkComponent}` (and `QuickCategoryComponent` if it calls the context), `ReimbursementLive.Index`, `TransferLive.Index`, `AutomationLive.Index`, `MonthLive.Show` transaction calls, and `Api.TransactionController`.

Not in scope: `Installments` and `InstallmentDetector`, `Forecast`, `CreditCards`, `Imports`, `Parsers.Ingestor`, mix tasks, `AdminDatabaseLive`, the scoping audit test, removal of the Repo insert override / `Ownership.assign/1` / `current_user!/0`, per-user uniqueness (`transactions.fingerprint` and `bulk_ignore_patterns.pattern` stay global). Those callers get only mechanical call-site updates.

## Approach

### Behavior
- **Signatures.** Every public `Transactions` function that touches rows takes `%CashLens.Users.User{}` first, including all `list_*`, `get_*`, `count_*`, summaries and breakdowns, `latest_transaction_date*`, `create_*`, `update_*`, `delete_*`, `duplicate_of`, `update_transaction_category`, `reapply_*`, link/unlink/reject functions, `get_transfer_pairs`, `get_reimbursement_pairs`, `create_mirror_transaction`, `suggest_installment_link`, `summary_excluded_category_ids`, `statement_health`. Pure functions stay unchanged (`change_*` changesets, `empty_filtered_summary`, `default_page_size`, `spend_rate`, `Transaction.dedup_key/1`). `TransferMatcher.match_transfers/match_transfer`, `TransferRuleApplier.apply_rules/maybe_apply_rule`, `AutoCategorizer.categorize`, `CategorySuggester.suggest_for/annotate` take the user first; their rule, category and candidate lookups are owned-only.
- **Filtering.** Every query goes through `Ownership.scope/2` on each table, joins and subqueries included (transactions, categories, accounts, transfer rules, bulk ignore patterns, rejected pairs). A transaction of A joined to a category or account of B never matches or counts. The excluded-summary-category lookup is scoped too.
- **Reads.** `get_*!` raises `Ecto.NoResultsError` for another user's id; list/summary functions return only the user's rows; zero-state summaries for users without data.
- **Writes.** `update_*(user, record, attrs)` and `delete_*(user, record)` (transactions, transfer rules, bulk ignore patterns) re-fetch by `record.id` via `scope/2` and return `{:error, :not_found}` for another user's row, leaving it unchanged. `update_transaction_category(user, id, category_id)` likewise, and `category_id` must be owned. Bulk operations (`reapply_*`, bulk ignore, `delete_all_transactions`, link/unlink, reject) only touch the user's rows; ids that are not owned are dropped and, when none of the supplied ids is owned (or any is foreign for link operations), return `{:error, :not_found}` and change nothing. Creates set `user_id` from the user; a `"user_id"` in attrs is ignored. Mirror transaction creation requires both the source transaction and the destination account to be owned.
- **Foreign keys.** `Transaction.changeset` calls `Ownership.validate_owned/3` for `:account_id` and `:category_id`; `TransferRule` and `BulkIgnorePattern` changesets do the same for their account/category fields; `RejectedReimbursementPair` for its transaction ids. A foreign id yields a changeset error on that field, not a DB error. (`installment_group_id`/`parent_id` belong to part 5.)
- **Callers outside this task** (`Accounting`, `BalanceAdjuster`, `Installments`, `Forecast`, `CreditCards` and `Matcher`, `Ingestor`, `Categories`, `Accounts`, `PageController`, `AccountLive.Index`, `CategoryLive.Index`, `migrate_credit_card_transfers`) keep compiling and passing: web callers pass `current_user`; others use `Ownership.current_user!/0` marked `# TRANSITIONAL: removed when CL-51 converts the caller`. No behavior change there.
- **Web.** `TransactionLive.Index` (and components), `ReimbursementLive.Index`, `TransferLive.Index`, `AutomationLive.Index`, `MonthLive.Show` use `socket.assigns.current_user` in `mount`, `handle_params`, `handle_event`, `handle_info` and async callbacks. `/transactions/:id` and `/transactions/:id/edit` for another user's id redirect to `/transactions` with an error flash and render none of the data. Event params carrying ids (bulk ignore selections, delete, link/unlink transfer, reimbursement link, quick category, mirror creation) are resolved through scoped getters; a forged foreign id is rejected with an error flash and changes no row.
- **API.** `Api.TransactionController` passes `conn.assigns.current_user`; `GET/PUT/DELETE /api/transactions/:id` for another user's record returns `404` through the existing fallback and leaves it unchanged; `index` returns only the user's rows (a foreign `account_id`/`category_id` filter yields an empty list).

### Files touched
- `lib/cash_lens/transactions.ex`: user first argument, `scope/2` on all queries, owner set on creates, `{:error, :not_found}`.
- `lib/cash_lens/transactions/{transfer_matcher,transfer_rule_applier,auto_categorizer,category_suggester}.ex`: user first, scoped lookups.
- `lib/cash_lens/transactions/{transaction,transfer_rule,bulk_ignore_pattern,rejected_reimbursement_pair}.ex`: `validate_owned` on caller-supplied foreign keys.
- `lib/cash_lens_web/live/transaction_live/*`, `reimbursement_live/index.ex`, `transfer_live/index.ex`, `automation_live/index.ex`, `month_live/show.ex`, `controllers/api/transaction_controller.ex`: pass the user, not-found handling.
- Mechanical call-site updates in the files listed under "Callers outside this task" and anything else the compiler flags.
- Existing tests and `test/support/fixtures/transactions_fixtures.ex` updated to the new signatures.
- New: `test/cash_lens/transactions_tenancy_test.exs`, `test/cash_lens_web/controllers/api/transaction_controller_tenancy_test.exs`; cases appended to the transaction, reimbursement, transfer and automation live tests and to the helper module tests.

### Test criteria
- Context tenancy (via `cross_tenant`; A owns accounts, categories, transactions, rules, patterns, rejected pairs): for B every `list_*`, summary, breakdown and suggestion function returns `[]`/empty summary; `get_transaction!`, `get_transfer_rule!`, `get_bulk_ignore_pattern!` raise `Ecto.NoResultsError`; `update_*`, `delete_*`, `update_transaction_category`, link/unlink and reject return `{:error, :not_found}`; A's rows are unchanged in the DB. A monthly total for B never includes A's transactions in the same month.
- Foreign keys: B creating a transaction with A's `account_id` or `category_id` (and a transfer rule with A's category) gets a changeset error on that field and no row is inserted.
- Helpers: with identical-looking data owned by A and B, `TransferMatcher`, `TransferRuleApplier`, `AutoCategorizer` and `CategorySuggester` called for B never match, apply, or suggest from A's transactions, rules or categories.
- API, logged in as B: `GET/PUT/DELETE /api/transactions/:id` for A's id returns `404`, A's row unchanged; index lists only B's rows.
- LiveView, logged in as B: `/transactions/:id` and `/transactions/:id/edit` for A's id redirect with a flash and the page lacks A's data; list pages show only B's rows; forged bulk-ignore, link and reimbursement events with A's ids give an error flash and change no row.
- Full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] Public functions of `Transactions`, `TransferMatcher`, `TransferRuleApplier`, `AutoCategorizer` and `CategorySuggester` take the user first and filter every table, joins and subqueries included, through `Ownership.scope/2`.
- [ ] `update_*` and `delete_*` return `{:error, :not_found}` for another user's record and leave it unchanged, proven by `transactions_tenancy_test.exs`.
- [ ] `transactions_tenancy_test.exs` proves user B gets empty lists, `nil` or `Ecto.NoResultsError` for user A's rows across transactions, transfer rules, bulk ignore patterns and rejected pairs.
- [ ] Creating a transaction with an `account_id` or `category_id` owned by another user fails with a changeset error on that field.
- [ ] `GET/PUT/DELETE /api/transactions/:id` for another user's record returns `404` and leaves the record unchanged.
- [ ] `/transactions/:id` and `/transactions/:id/edit` for another user's id redirect to `/transactions` with an error flash without rendering the data.
- [ ] A forged id from another user in bulk ignore, link or reimbursement events gives an error flash and changes no row.

## Out of Scope
- Installments, Forecast, CreditCards, Imports, Ingestor, mix tasks, `AdminDatabaseLive` (later CL-51 parts).
- Removing the Repo override, `Ownership.assign/1`, `current_user!/0`; the scoping audit test.
- Per-user uniqueness of fingerprints and ignore patterns.
