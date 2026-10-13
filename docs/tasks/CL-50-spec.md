# CL-50 — Add user ownership schema and backfill existing data

## Scope
Part 2 of the CL-20 split. Every domain table gains a `user_id` column, NOT NULL, with a foreign key to `users` and a supporting index. Existing rows are backfilled to the operator user. Every Ecto schema declares `belongs_to :user`.

The 12 domain tables: `accounts`, `categories`, `installment_groups`, `transactions`, `balances`, `bulk_ignore_patterns`, `transfer_rules`, `rejected_reimbursement_pairs`, `recurring_items`, `credit_card_statements`, `imported_files`, `import_runs`. Not included: `users`, `schema_migrations`, `oban_*` tables.

Not covered: filtering queries by user, per-user uniqueness, or populating `user_id` from the request in the app (CL-20 parts 3+). See Out of Scope.

## Approach
Behavior
- One migration, `priv/repo/migrations/<ts>_add_user_id_to_domain_tables.exs`, using explicit `up`/`down`. For each table, in order: add `user_id` (binary_id, nullable), backfill, `ALTER ... SET NOT NULL`, add the FK to `users(id)`, create an index on `user_id`. Doing this in separate steps lets the backfill run on populated tables.
- FK delete behavior is `ON DELETE RESTRICT` (default `:nothing` semantics are fine). Deleting a user that still owns data must fail, never cascade away financial data.
- Operator user resolution (inside the migration, plain SQL, no app modules):
  1. If env var `CASH_LENS_OPERATOR_EMAIL` is set, use the user with that email (case-insensitive, citext). If it is set and no such user exists, raise with a clear message.
  2. Else, if exactly one row exists in `users`, use it.
  3. Else, if every domain table is empty, no operator is needed and the migration just adds the constraints.
  4. Else (data present and zero or several users, no env var), raise before changing anything, naming the env var to set. The check runs before any `ALTER`.
  The operator need not be `enabled` for the backfill; the user must simply exist (the operator registers first via CL-49, then runs the migration).
- Backfill is a single `UPDATE <table> SET user_id = $operator WHERE user_id IS NULL` per table.
- Rollback: `down` drops the indexes, FKs and `user_id` columns of all 12 tables. Documented in the migration moduledoc: rollback discards ownership info, which is acceptable because it was derived from a single operator.
- Each schema in the 12 modules gets `belongs_to :user, CashLens.Users.User` (binary_id foreign key, matching the project's id type). Changesets are not required to cast or validate `user_id` here, to keep existing call sites working; callers that insert rows without a user are expected to break only at the DB level, so test fixtures and any non-test insert paths (importers, Mix tasks, seeds) must be updated to set `user_id` so the suite stays green. Fixtures get a shared user fixture (reuse the CL-49 users fixture).
- `AGENTS.md` file map/notes updated to say all domain tables are user-owned.

Files touched
- `priv/repo/migrations/<ts>_add_user_id_to_domain_tables.exs`: the migration above.
- The 12 schema modules (`accounts/account.ex`, `categories/category.ex`, `installments/installment_group.ex`, `transactions/transaction.ex`, `transactions/bulk_ignore_pattern.ex`, `transactions/transfer_rule.ex`, `transactions/rejected_reimbursement_pair.ex`, `accounting/balance.ex`, `forecast/recurring_item.ex`, `credit_cards/statement.ex`, `imports/imported_file.ex`, `imports/import_run.ex`): add `belongs_to :user`.
- `test/support/fixtures/*.ex` and tests/code paths that insert rows directly: set `user_id`.
- Any production insert path that builds these structs without a user (importers, Mix tasks, `priv/repo/seeds.exs`): minimally pass a user through or resolve the operator, without redesigning them.
- `AGENTS.md`: doc update.

Test criteria
- `test/cash_lens/user_ownership_test.exs` (new):
  - for each of the 12 tables, `information_schema.columns` shows `user_id` with `is_nullable = 'NO'`, and `information_schema` / `pg_constraint` shows an FK to `users`;
  - for each table, `pg_indexes` has an index whose definition begins with `user_id`;
  - inserting a row with a random non-existent `user_id` raises `Postgrex.Error` with code `foreign_key_violation` (at least for `accounts` and `transactions`);
  - every schema module in the list has `:user` among its `__schema__(:associations)`;
  - deleting a user that owns an account fails with a foreign key violation.
- Backfill test (migration test, may run the migration's `up` logic against a scratch state, or be a documented manual check if Ecto sandbox makes this impractical): with rows present in tables, a single user, and no env var, rows end with `user_id` equal to that user; with two users and no env var, the migration raises and leaves the tables unchanged; with the env var naming the second user, rows go to that user.
- Manual verification recorded in the report: restore a production-shaped dump from `backups/` into a scratch database, create the operator user, run `mix ecto.migrate`, confirm zero null `user_id` in every table; run `mix ecto.rollback` and migrate again.
- Full `mix test` passes.

## Expected Results
- [ ] Each of the 12 domain tables has `user_id` NOT NULL with an FK to `users` (asserted in `user_ownership_test.exs` via `information_schema`/`pg_constraint`).
- [ ] Each `user_id` column has an index, asserted via `pg_indexes` in `user_ownership_test.exs`.
- [ ] Running the migration on populated tables assigns every existing row to the operator user, leaving no null `user_id` in any table.
- [ ] Inserting a row with a non-existent `user_id` fails with a `foreign_key_violation`.
- [ ] The migration applies to a restored production-shaped dump with no errors.
- [ ] `mix ecto.rollback` of the migration succeeds on the migrated dump.
- [ ] Every one of the 12 Ecto schemas declares `belongs_to :user`.
- [ ] The full `mix test` suite passes.

## Out of Scope
- Scoping queries, contexts, LiveViews or API by the current user.
- Per-user uniqueness: unique indexes such as `transactions.fingerprint`, `categories.slug`, `imported_files.path`, `bulk_ignore_patterns.pattern` stay global for now (follow-up in later CL-20 parts).
- Row-level security, user deletion flow, admin UI, ownership of Oban jobs.
