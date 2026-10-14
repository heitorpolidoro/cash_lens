# CL-61 — Scope imports and tooling by user, then remove the owner fallback

## Scope
Part 7 of the CL-51 split (CL-51 spec, steps 8-9). It follows CL-60 and the sibling specs CL-55..CL-59, which already scoped the other contexts, so callers of `Imports` and the Ingestor are on the user-first convention. This task (a) threads the user through the import pipeline, the six mix tasks, the seeds, `ImportLive` and `AdminDatabaseLive`, and (b) then removes the interim owner fallback and adds the scoping audit test.

Not in scope: per-user uniqueness (unique indexes on `transactions.fingerprint`, `imported_files.path`, `categories.slug`, ... stay global), row-level security work (CL-53), user deletion, admin UI redesign. The Repo pin API stays for CL-53: `Repo.put_current_user_id/1`, `Repo.current_user_id/0`, `Repo.with_user/2` (and `Ownership.put_user_id/1` / `pinned_user_id/0` behind them).

## Approach

### Part A — import pipeline and tooling (CL-51 step 8)
- **Imports context.** Every public function that reads or writes `imported_files` or `import_runs` (`get_imported_file_by_path`, `map_by_paths`, `upsert_imported_file`, `record_run`, `list_recent_runs`, `account_for_entry`, `candidate_accounts`, any other row-touching one) takes `%User{}` first and filters through `Ownership.scope/2`; creates set `user_id`. Pure helpers (`scan`, `import_root`, `content_hash`, `relative_path`, `validate_drop`, `stage_drop`, drop-directory helpers, `preselect_account`) are unchanged. Account lookups only match accounts owned by the user.
- **`Parsers.Ingestor` and `Parsers.DirectoryImporter`.** `import_file`, `import_directory`, `preview_file`, `run`, `preflight`, `each_credit_card_file` and other row-touching functions take the user first. Transactions, statements and balances (including `insert_all` row maps) get that `user_id`; the `Ownership.current_user_id!()` call near ingestor.ex:617 and the `SyncRecurringWorker.enqueue()` shim are replaced by the user id. Accounts, categories, transfer rules, duplicate/fingerprint checks, transfer matching and installment/credit-card matching run only among that user's rows via the already-scoped context functions.
- **Operator resolver (one implementation).** New module `CashLens.Operator` in `lib/cash_lens/operator.ex` with `user!/1`, taking the `--user` email or `nil` and returning a `%User{}`. A given email must match a user, else it raises `Mix.Error`; with `nil` it returns the only user, and raises `Mix.Error` with a usage message for zero or several users. It is the sole tooling-side way to pick a user and is called before any write. It lives under `lib/` (not in `Ownership`, not in `lib/mix/`) so it is compiled in every env and reachable from `mix run`.
- **Mix tasks.** `cash_lens.import`, `cash_lens.backfill_statements`, `cash_lens.migrate_ourocard_txt`, `cash_lens.recompute_competencia`, `cash_lens.reconcile_pending_statements` and `cash_lens.migrate_credit_card_transfers` accept `--user <email>`, call `CashLens.Operator.user!/1` in place of `Ownership.pin_operator!()`, and pass the resulting user to every context call.
- **Seeds.** `priv/repo/seeds.exs` calls `CashLens.Operator.user!/1` directly (seeds run through `mix run`, so the app modules are loaded), with the email taken from the `CASH_LENS_OPERATOR_EMAIL` env var (a `--user` script arg is not supported), and inserts the three base categories with that user's id.
- **`ImportLive`** passes `socket.assigns.current_user` in mount, upload consumption, `handle_event`, `handle_info` and async callbacks, including recent runs and account candidates.
- **`AdminDatabaseLive`**: for the 12 domain tables (`Ownership.domain_schemas/0`) lists, counts and paginates only rows with `user_id == current_user.id`; other tables behave as today.

### Part B — lockdown (CL-51 step 9), after Part A is green
- `CashLens.Repo`: delete the `insert/2` and `insert!/2` overrides that call `Ownership.assign/1`; keep a plain RLS-binding wrapper for inserts if the other writes use one, with no owner assignment. Fix the stale comment above `defoverridable`.
- `CashLens.Ownership`: delete `assign/1`, `current_user_id!/0`, `pin_operator!/0`, `maybe_create_owner!/0` and the `:auto_create_owner` branch; rewrite the moduledoc. Keep `domain_schemas/0`, `scope/2`, `validate_owned/3`, `put_user_id/1` and `pinned_user_id/0`; the operator helper is `CashLens.Operator.user!/1`, not part of `Ownership`. Remove `config :cash_lens, :auto_create_owner, true` from `config/test.exs`.
- Remove remaining callers of the deleted functions (the two Oban workers still call `pin_operator!`; replace with their `user_id` arg handling or `Repo.with_user/2`).
- Tests relying on auto-created owners (`transactions_test.exs`, `category_suggester_test.exs`, `user_ownership_test.exs`, `user_ownership_migration_test.exs`, `privacy_test.exs`, the transaction and automation live tests) pass an explicit user; `user_ownership_test.exs` keeps a case proving an insert without `user_id` fails instead of getting an owner.
- **Scoping audit test** `test/cash_lens/user_scoping_audit_test.exs`, as in the CL-51 "Guard check": reads every `.ex` under `lib/`, splits into blocks at each `def`/`defp`, fails for a block matching `Repo\.(all|one|get|get!|get_by|get_by!|update_all|delete_all|aggregate|exists\?|stream|insert_all)\(` or `\bfrom\(?\s*\w+\s+in\s+` that contains neither `Ownership.scope(` nor `user_id`. The `@allow_list` attribute at the top holds only `lib/cash_lens/{users,audit,health,privacy,ownership,operator,application}.ex`, each with a reason comment. Any other offender is fixed in code, not allow-listed.
- `AGENTS.md`: update the ownership section and the `Ownership` file-map entry (no fallback; `scope/2`, `validate_owned/3`, `CashLens.Operator.user!/1` for mix tasks and seeds only) and add the convention "the first argument of context functions is the `%User{}`".

### Files touched
- `lib/cash_lens/imports.ex`, `lib/cash_lens/imports/*.ex`: user-first, scoped.
- `lib/cash_lens/parsers/ingestor.ex`, `directory_importer.ex`: user threaded.
- `lib/cash_lens_web/live/import_live/*`, `lib/cash_lens_web/live/admin_database_live.ex`: `current_user`.
- `lib/cash_lens/operator.ex` (new): `user!/1` resolver.
- `lib/mix/tasks/*.ex` (six tasks): `--user`; `priv/repo/seeds.exs`: `CASH_LENS_OPERATOR_EMAIL`.
- `lib/cash_lens/repo.ex`, `lib/cash_lens/ownership.ex`, `config/test.exs`, the two workers: lockdown.
- `AGENTS.md`: docs.
- Tests: update `imports_test.exs`, ingestor/importer/import-live/mix-task tests and those listed above; new `imports_tenancy_test.exs`, per-user import test, mix task and seeds tests, `admin_database_live` test, `user_scoping_audit_test.exs`.

### Test criteria
- `imports_tenancy_test.exs` (shared `cross_tenant` helper): B's `list_recent_runs`, `get_imported_file_by_path`, `map_by_paths` return empty/nil for A's data; writes are owned by the caller; A's rows unchanged.
- Import test: A and B import different files (distinct data, as uniqueness is still global); every resulting `imported_files`, `import_runs`, `transactions`, `statements`, `balances` row has its importer's `user_id`; no transfer pair links two users' rows; B's import cannot resolve A's account.
- Mix tasks, seeds and `Operator.user!/1`: `--user a@x` creates rows owned by A; two users and no flag aborts with tables unchanged; one user and no flag uses it; unknown email aborts.
- `ImportLive` logged in as B shows only B's runs; `AdminDatabaseLive` as B lists none of A's rows in a domain table.
- Audit test passes, and a unit test feeding the scanner an unscoped snippet sees it flagged.
- Inserting a domain schema without `user_id` fails; `CashLens.Ownership.assign/1` is not exported and `:auto_create_owner` is absent from `config/`; `Repo.with_user/2` still works.
- Full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] `test/cash_lens/imports_tenancy_test.exs` passes, showing user B's `Imports` reads return nothing of user A's runs and files.
- [ ] An import test with distinct data per user passes, with every created `transactions` row owned by its importer.
- [ ] `CashLens.Operator.user!/1` raises `Mix.Error` when several users exist and no email is given, proven by a passing test.
- [ ] `mix cash_lens.import --user <email>` creates rows owned by that user, proven by a passing mix task test.
- [ ] `AdminDatabaseLive` logged in as user B lists none of user A's rows in a domain table, proven by a passing LiveView test.
- [ ] `test/cash_lens/user_scoping_audit_test.exs` passes with `@allow_list` limited to the seven commented files.
- [ ] Inserting a domain row without `user_id` fails with a database error, proven by a passing `user_ownership_test.exs` case.
- [ ] `mix precommit` and the full `mix test` pass.

## Out of Scope
- Per-user unique indexes, row-level security changes (CL-53), user deletion flow, admin UI redesign.
