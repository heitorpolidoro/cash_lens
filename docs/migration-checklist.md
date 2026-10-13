# Migration safety checklist

Every migration is reviewed against this list before it is merged, and the result
is written in the PR (or, for the ones below, in "Completed checks"). Outcome per
item: **pass**, **n.a.**, or **accepted risk** with a one-line justification. A
silent skip is not an outcome.

1. **Backward compatible with the previous release (expand/contract).** The code
   that is still running while the migration applies must keep working. Add
   nullable columns and new tables first, ship the code that uses them, tighten
   (`NOT NULL`, drop) in a later release.
2. **No long `ACCESS EXCLUSIVE` locks.** Create indexes with
   `create index(..., concurrently: true)` and `@disable_ddl_transaction true` /
   `@disable_migration_lock true`. Add constraints as `NOT VALID`, then
   `VALIDATE CONSTRAINT` in a separate step. A `SET NOT NULL` that scans a big
   table counts as a long lock. Set `lock_timeout` for DDL that cannot be avoided.
3. **Backfills are batched and idempotent.** Update in bounded batches (not one
   `UPDATE` over the table), with a `WHERE` that makes a re-run a no-op, and keep
   them out of the DDL transaction when large.
4. **`up` and `down` are defined**, or the migration states why it is
   irreversible (what is lost) in its moduledoc.
5. **New tables carry `user_id`, RLS and grants.** `user_id uuid NOT NULL`
   referencing `users`, an index on it, `ENABLE` + `FORCE ROW LEVEL SECURITY`
   with the `user_isolation` policy (copy it from
   `20261014120000_enable_row_level_security.exs`), and the table must be added
   to `CashLens.Ownership`/`CashLens.Privacy` and to `@tables` in
   `test/cash_lens/rls_test.exs`. Grants to `cash_lens_app` come from the default
   privileges in `priv/repo/roles.sql`; re-run provisioning to be sure.
6. **Encrypted pre-migration backup.** `BACKUP_AGE_RECIPIENT=... scripts/backup.sh`
   immediately before migrating production, and the file name noted in the PR.
7. **Run as the owner role.** `mix ecto.migrate` goes through
   `CashLens.MigrationRepo` (`MIGRATION_DATABASE_URL` in prod). Never migrate as
   `cash_lens_app`; it owns nothing and cannot do DDL. Run
   `mix cash_lens.db.provision` and `mix cash_lens.db.verify_role` afterwards.
8. **Rehearsed on a copy.** Restore the latest backup into a scratch database,
   run the migration there, run the app's smoke checks, and only then migrate
   production.

## Completed checks

### CL-50: `20261013130000_add_user_id_to_domain_tables`

| # | Item | Result | Why |
|---|---|---|---|
| 1 | Backward compatible | accepted risk | Adds `user_id NOT NULL`: an insert from the previous release (no `user_id`) fails after it. Single instance, code and migration deploy together, and `CashLens.Ownership` fills the owner in the new code. |
| 2 | No long exclusive locks | accepted risk | `SET NOT NULL`, the FK and a plain (non-concurrent) index each lock the table while they scan it. The 12 tables are small (one operator's personal finance data) and the migration runs in a maintenance window; it would be a fail on a large tenant table. |
| 3 | Backfill batched, idempotent | accepted risk | One `UPDATE ... WHERE user_id IS NULL` per table: idempotent, not batched. Same size argument as item 2. |
| 4 | `up`/`down` | pass | Both defined; `down` drops indexes, FKs and columns, and the moduledoc says that discards ownership. |
| 5 | New tables: `user_id`, RLS, grants | n.a. | Adds `user_id` to existing tables; RLS follows in the CL-53 migration. |
| 6 | Encrypted pre-migration backup | accepted risk | `scripts/backup.sh` did not exist yet; the operator took an ad hoc `pg_dump` (plaintext, see `docs/security.md`). |
| 7 | Run as owner role | pass | Runs through `MigrationRepo` (owner); before CL-53 the single superuser did both jobs. |
| 8 | Rehearsed on a copy | pass | `test/cash_lens/user_ownership_migration_test.exs` runs `up`/`down` against data in every path (single user, env var, several users, empty, data with no user). A restore-to-scratch rehearsal is the operator's step before production. |

### CL-53: `20261014120000_enable_row_level_security`

| # | Item | Result | Why |
|---|---|---|---|
| 1 | Backward compatible | accepted risk | Changes no column, but a release that does not bind `app.current_user_id` sees no rows once the policies exist (fail-closed by design). Deploy it with the CL-53 code and after provisioning `cash_lens_app`; single instance, no overlap of releases. |
| 2 | No long exclusive locks | pass | `ENABLE`/`FORCE ROW LEVEL SECURITY` and `CREATE POLICY` are catalog-only changes: `ACCESS EXCLUSIVE` for milliseconds, no table scan, no rewrite. |
| 3 | Backfill batched, idempotent | n.a. | No data is touched. |
| 4 | `up`/`down` | pass | `down` drops the policy, then `NO FORCE` and `DISABLE`. `user_ownership_migration_test.exs` runs it down before CL-50's `down`, because the policies reference `user_id`. |
| 5 | New tables: `user_id`, RLS, grants | pass | Creates no table. It covers all 12 `user_id` tables and `rls_test.exs` fails if a table with a `user_id` column is left out. |
| 6 | Encrypted pre-migration backup | pass | `scripts/backup.sh` exists now (`age`-encrypted, retention enforced); take one before migrating production. |
| 7 | Run as owner role | pass | `MigrationRepo`; the owner needs `BYPASSRLS` or superuser so `pg_dump` and maintenance still work under `FORCE`. |
| 8 | Rehearsed on a copy | pass | `rls_test.exs` asserts the final catalog state (RLS enabled and forced, one policy) and cross-user isolation; the migration test runs its `down` in a sandboxed transaction (and rolls it back). A restore-to-scratch rehearsal is the operator's step before production. |
