# CL-53 — Database security review and hardening

## Scope
Part 5 of the CL-20 split. Hardens the PostgreSQL layer before public launch, on top of CL-50 (which adds `user_id NOT NULL` FK + index to 12 domain tables and deliberately leaves RLS, per-user uniqueness and query scoping out). Covers: a least-privilege runtime role, row-level security (RLS), SSL to the database in production, encrypted backups with a retention policy, and a migration safety checklist.

Does NOT cover: per-user unique indexes, application-level query scoping by `user_id` (sibling tasks of CL-20), DB provider selection, off-site backup transport, key rotation.

Note for the developer: CL-50's spec and files were not present in the working tree when this spec was written. Re-read CL-50's final migration for the exact list of user-owned tables and the `user_id` type; derive the RLS migration from that list, not from memory. `users` itself is not user-owned.

## Approach

### 1. Roles (least privilege)
- Two roles: an owner/migrator role (owns tables, runs DDL, used only by `mix ecto.migrate` / release migration) and an app role `cash_lens_app` (runtime). The app role is `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`, has `CONNECT` only on the app database, `USAGE` on schema `public`, `SELECT/INSERT/UPDATE/DELETE` on tables and `USAGE/SELECT` on sequences, no `CREATE` on the schema, and owns nothing (an owner would bypass RLS). `REVOKE CONNECT` on the database and `CREATE` on schema `public` from `PUBLIC`.
- Provisioning is an idempotent SQL script `priv/repo/roles.sql` (password passed as a psql variable, never committed) with `ALTER DEFAULT PRIVILEGES` so future tables/sequences are granted to the app role.
- Config: prod `config/runtime.exs` reads `DATABASE_URL` (app role) for the Repo and `MIGRATION_DATABASE_URL` (owner) for migrations; both raise when missing. Dev (`docker-compose.yml`, `dev.env`) and test use the same split (migrations as owner, runtime Repo as app role).
- A mix task `mix cash_lens.db.verify_role` connects as the app role and asserts: `CREATE TABLE`, `DROP TABLE` and `ALTER ROLE` fail; `rolsuper`, `rolcreatedb`, `rolcreaterole`, `rolbypassrls` are all false; connecting to another database is refused. Exits non-zero on any deviation. Documented in `docs/security.md`.

### 2. Row-level security
- New migration: for each user-owned table, `ENABLE` and `FORCE ROW LEVEL SECURITY` and one policy with `USING` and `WITH CHECK` of `user_id = NULLIF(current_setting('app.current_user_id', true), '')::<user_id type>`. An unset setting fails closed (no rows visible, inserts rejected). Reversible.
- `CashLens.Repo` gets a single choke point that binds a process-scoped current user id to the DB session via a transaction-local `set_config('app.current_user_id', id, true)`, plus an explicit `with_user/2`. The setting must never leak to the next checkout of a pooled connection. The mechanism is the developer's choice subject to that guarantee and to living in `CashLens.Repo`, not at call sites.
- The current user is set where the authenticated user is established (router pipeline / LiveView `on_mount`) and explicitly in import/background code. Maintenance paths (backfills, mix tasks, migrations) use the owner role or `with_user/2`; none relies on `BYPASSRLS` for the app role.
- Test helpers (`DataCase`, `ConnCase`, fixtures) set the current user so the whole suite runs under RLS.

### 3. SSL in production
- `config/runtime.exs` (prod): `ssl: true` with `ssl_opts` `verify: :verify_peer`, CA from `DATABASE_CA_CERT_PATH` (fallback to the system CA store), and SNI / hostname check derived from the DB host. Applies to the app Repo and the migration connection. No opt-out env var; dev/test stay without SSL. Documented in `docs/security.md`.

### 4. Encrypted backups and retention
- New `scripts/backup.sh` (no backup script exists today; `backups/` holds ad hoc dumps): `pg_dump -Fc` as the owner role, encrypted with `age` to the public key in `BACKUP_AGE_RECIPIENT`, output `backups/cash_lens_backup_<UTC timestamp>.dump.age` with mode 600, plaintext dump removed (also on failure), then prune by retention. Aborts non-zero if the recipient is unset.
- Retention (documented in `docs/security.md`, enforced by the script): daily kept 7 days, weekly (Sunday) 4 weeks, monthly (1st) 6 months. Documented restore procedure (`age -d | pg_restore`) and the advice to rehearse it. `backups/` stays git-ignored; existing plaintext `.dump` files are flagged for the operator to encrypt or delete (the script does not delete them).

### 5. Migration safety checklist
- New `docs/migration-checklist.md`: backward compatible with the previous release (expand/contract); no long `ACCESS EXCLUSIVE` locks (`CONCURRENTLY` indexes with `@disable_ddl_transaction`, `NOT VALID` then `VALIDATE`); backfills batched and idempotent; `up`/`down` defined or explicit irreversible note; new tables get `user_id`, RLS and grants to the app role; encrypted pre-migration backup; run as owner role; rehearsed on a copy.
- The same doc records a completed check of CL-50's `add_user_id_to_domain_tables` and the CL-53 migration against each item (pass / n.a. / accepted risk, one-line justification).

## Files touched
- `priv/repo/migrations/<ts>_enable_row_level_security.exs` — RLS enable/force and policies.
- `priv/repo/roles.sql` — role provisioning and default privileges.
- `lib/cash_lens/repo.ex` — current-user binding, `with_user/2`.
- `lib/mix/tasks/cash_lens.db.verify_role.ex` — role verification task.
- `config/runtime.exs`, `config/dev.exs`, `config/test.exs`, `dev.env`, `docker-compose.yml`, `mix.exs` — two-role split, prod SSL, test aliases.
- Router pipeline / LiveView `on_mount` / import code — set the current user.
- `test/support/data_case.ex`, `conn_case.ex`, fixtures — set the current user.
- `scripts/backup.sh` — encrypted backup and retention.
- `docs/security.md`, `docs/migration-checklist.md`, `AGENTS.md` — documentation and two-role dev setup.

## Test criteria
- `test/cash_lens/rls_test.exs`: with rows for users A and B in every user-owned table, A sees only A rows and B only B rows; with no user set zero rows; inserting with another user's `user_id` raises; `UPDATE`/`DELETE` under A affect 0 of B's rows.
- Role test (or the verify task in CI): the app role cannot `CREATE`/`DROP`/`ALTER`, is not superuser or bypassrls, and cannot connect to another database.
- `test/cash_lens/runtime_config_test.exs` (style of `endpoint_config_test.exs`): prod runtime config has `ssl: true`, `verify: :verify_peer`, a CA source, and raises when `DATABASE_URL` or `MIGRATION_DATABASE_URL` is unset.
- Backup check: `scripts/backup.sh` without `BACKUP_AGE_RECIPIENT` exits non-zero and leaves no plaintext; with a throwaway age key it yields a `.dump.age` that restores.
- Full `mix test` passes with the non-owner app role and forced RLS.

## Expected Results
- [ ] The Repo connects as `cash_lens_app` (no superuser, createdb, createrole or bypassrls), and `mix cash_lens.db.verify_role` exits 0 only when `CREATE TABLE`, `DROP TABLE` and connecting to another database are all refused.
- [ ] Every user-owned table has RLS enabled and forced with a `user_id = current user setting` policy, and `rls_test.exs` shows a query under user B returns none of user A's rows (and none at all when no user is set).
- [ ] The prod Repo config in `config/runtime.exs` sets `ssl: true` with `verify: :verify_peer` and a CA source, asserted by a config test.
- [ ] `scripts/backup.sh` writes an `age`-encrypted `.dump.age`, leaves no plaintext dump, aborts without `BACKUP_AGE_RECIPIENT`, and prunes per the documented 7 daily / 4 weekly / 6 monthly retention.
- [ ] `docs/migration-checklist.md` exists and contains a completed check of the CL-50 and CL-53 migrations against it.
- [ ] `mix test` passes with the non-owner app role and forced RLS enabled.

## Out of Scope
Per-user unique indexes, query scoping in contexts, DB provider provisioning, automated off-site backup transport, key rotation.
