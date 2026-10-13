# Security controls

Controls added or pinned by CL-52 (hardening of the auth surface from CL-49).
Run `mix security` (`deps.audit` + `sobelow`) before opening a PR.

| Control | Where / config key | How it is tested |
|---|---|---|
| CSRF on every browser POST/DELETE; the session-based `/api` scope also requires the token (`x-csrf-token` header) | `:browser` and `:api` pipelines in `lib/cash_lens_web/router.ex` (`protect_from_forgery`) | `test/cash_lens_web/security_headers_test.exs` (403 for register, log_in, log_out and an API DELETE without a token) |
| Session cookie: signed **and encrypted**, `http_only`, `same_site: "Lax"`, `secure` in prod | `config :cash_lens, CashLensWeb.Endpoint, session_options: [...]` in `config/config.exs`; `secure: true` added in `config/prod.exs`; read by `endpoint.ex` at compile time (also feeds the LiveView socket) | `test/cash_lens_web/endpoint_config_test.exs` (evaluates the prod config with `Config.Reader.read!/2`) |
| Rate limiting of `POST /users/log_in` (5/min per IP, plus 5/min per submitted email) and `POST /users/register` (5/hour per IP); `429` + `retry-after` | `CashLensWeb.Plugs.RateLimit` (ETS, owner `CashLensWeb.Plugs.RateLimit.Store`); `config :cash_lens, CashLensWeb.Plugs.RateLimit, login: [...], register: [...], trust_proxy_headers: ...`. Test config sets very high limits | `test/cash_lens_web/plugs/rate_limit_test.exs` |
| Client IP for the limiter | `x-forwarded-for` (last entry, the one the proxy appended) is used only when `trust_proxy_headers: true`, set in `config/prod.exs`. Do not enable it without a reverse proxy | `rate_limit_test.exs`, `endpoint_config_test.exs` |
| Password policy: 12..72 **bytes**, not in `priv/common_passwords.txt` (case-insensitive), not equal to the email or its local part. Log in is not subject to it | `CashLens.Users.User.registration_changeset/2` | `test/cash_lens/users_test.exs`, `test/cash_lens_web/controllers/user_registration_controller_test.exs` |
| Browser headers: CSP (`default-src 'self'`, no `unsafe-eval`, script nonce per request, `frame-ancestors 'none'`, `base-uri`/`form-action 'self'`, `connect-src 'self'`), `x-content-type-options`, `referrer-policy`, `permissions-policy` | `CashLensWeb.Plugs.SecurityHeaders` in the `:browser` pipeline; the nonce is on the inline script of `root.html.heex` | `security_headers_test.exs` |
| TLS: `force_ssl` with `hsts: true`, 2 year `expires`, `rewrite_on: [:x_forwarded_proto]` | `config/prod.exs` | `endpoint_config_test.exs` |
| WebSocket origin | `check_origin: ["https://<PHX_HOST>"]` in `config/runtime.exs` (prod) | `endpoint_config_test.exs` (runtime config evaluated for prod) |
| Secrets only from the environment | `SECRET_KEY_BASE`, `DATABASE_URL` and `MIGRATION_DATABASE_URL` are read in `config/runtime.exs` and raise when missing. `config/prod.exs` and `config/config.exs` hold no secret (salts are not secrets: they only namespace key derivation from `secret_key_base`) | `endpoint_config_test.exs` (literal scan + runtime evaluation with each variable unset) |
| Upload validation: extension allow-list `.csv .pdf .ofx .txt` (case-insensitive), 10 MB cap, content check (`.pdf` starts with `%PDF`; the others have no NUL or binary control bytes; latin-1 text is accepted). The client file name is only a sanitized label | `CashLens.Imports.validate_drop/2`, called in the consume step of `ImportLive.Index`, so a crafted client cannot bypass `accept` | `test/cash_lens_web/live/import_live_upload_test.exs` |

## Audit result and secrets inventory

Production secrets: `SECRET_KEY_BASE`, `DATABASE_URL` (app role) and `MIGRATION_DATABASE_URL` (owner role), all required and raising when absent, plus `BACKUP_AGE_RECIPIENT` (a public key, for `scripts/backup.sh`). The Pluggy integration was dropped (see the `drop_pluggy` migration), so there are no API keys. Dev/test placeholders live in `config/dev.exs` and `config/test.exs` only.

Existing session cookies became invalid when `encryption_salt` was added (users log in again once).

## Static analysis and dependency audit

`mix security` runs `mix deps.audit` and `mix sobelow --config` (`.sobelow-conf`: threshold `high`, exit on high).
`mix_audit` and `sobelow` are dev/test-only dependencies. They are not wired into CI: the workflow is the shared `heitorpolidoro/.github/.github/workflows/elixir-ci.yml`, which this repository does not control. Follow-up: add `mix security` there.

Dependencies upgraded for advisories: `bandit`, `mint`, `phoenix`, `plug`, `postgrex`, `req` (and their transitive updates).

### Accepted exceptions

| Finding | Severity | Justification |
|---|---|---|
| `deps.audit`: `decimal` GHSA-rhv4-8758-jx7v (unbounded exponent in `Decimal.new`) | moderate | The fix is `decimal` 3.0, which `ecto` 3.13 does not allow (`~> 2.0`). `Decimal.new` is not fed with untrusted exponent notation: amounts come from parsers that strip to plain digits, and the app is login-gated. Ignored in the `security` alias in `mix.exs`; revisit when `ecto` allows `decimal` 3. |
| `sobelow`: `Config.Headers` ("Missing Secure Browser Headers") on the `:browser` pipeline | high (false positive) | Sobelow only recognizes `plug :put_secure_browser_headers`. The pipeline uses `CashLensWeb.Plugs.SecurityHeaders`, which calls `put_secure_browser_headers` with a stricter header set and is covered by `security_headers_test.exs`. Ignored in `.sobelow-conf`. |
| `sobelow`: `Traversal.FileModule` on `File.rm_rf` / `File.read` in `ImportLive.Index` (`unrecognized_drop`, `confirm_drop`, `discard_drop`) | low confidence | The paths are staging directories the server itself builds under the drop root from a random session id and a content hash; the client file name is reduced to a sanitized basename (`Imports.stage_drop/3`). Below the `high` threshold, so not reported by `mix security`. |

## Database hardening (CL-53)

| Control | Where | How it is tested |
|---|---|---|
| Least-privilege runtime role `cash_lens_app` (`LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`; `CONNECT` on the app database only, `USAGE` on schema `public`, DML on tables, `USAGE/SELECT` on sequences, no `CREATE`, owns nothing) | `priv/repo/roles.sql`, applied by `mix cash_lens.db.provision` or `psql` | `mix cash_lens.db.verify_role`, `test/mix/tasks/cash_lens_db_verify_role_test.exs` |
| Row-level security: enabled **and forced** on the 12 user-owned tables, one policy `user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid` for `USING` and `WITH CHECK`; unset setting means no rows and no inserts | `priv/repo/migrations/20261014120000_enable_row_level_security.exs`; binding in `CashLens.Repo` | `test/cash_lens/rls_test.exs` (and the whole suite, which runs as the app role) |
| TLS to the database, always verified (`verify: :verify_peer`, CA from `DATABASE_CA_CERT_PATH` or the system store, host name checked); no opt-out variable | `config/runtime.exs` (prod), both repos | `test/cash_lens/runtime_config_test.exs` |
| Encrypted backups with retention | `scripts/backup.sh` | `test/scripts/backup_script_test.exs` |
| Migration safety | `docs/migration-checklist.md` | reviewed per migration |

### Two roles

| Role | Used by | Connects with |
|---|---|---|
| owner / migrator (dev default `postgres`) | `mix ecto.migrate`, `mix cash_lens.db.provision`, `scripts/backup.sh`, the migration test | `CashLens.MigrationRepo`; prod `MIGRATION_DATABASE_URL`; dev/test `DATABASE_USER`, `DATABASE_PASSWORD` |
| `cash_lens_app` | the running app, Oban, the whole test suite | `CashLens.Repo`; prod `DATABASE_URL`; dev/test `DATABASE_APP_USER`, `DATABASE_APP_PASSWORD` (default `cash_lens_app` / `cash_lens_app`, dev and test only) |

`CashLens.MigrationRepo` shares `priv/repo` with the runtime repo, is the only entry in `ecto_repos`, and is never started with the app outside the test env. Runtime code must not use it.

The owner role needs `BYPASSRLS` (or superuser): `FORCE ROW LEVEL SECURITY` also binds the owner, and `pg_dump` aborts on a table it would only see partly. In dev and test the owner is the superuser `postgres`. In production give the owner `BYPASSRLS` and keep it off the app's network path: it is only for deploy-time migration, backups and role provisioning.

#### Provisioning

Idempotent, run it after every migration:

```
# with psql
psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -v app_password="$APP_DB_PASSWORD" -f priv/repo/roles.sql
# or, without psql (reads CASH_LENS_APP_PASSWORD, falling back to the Repo password)
mix cash_lens.db.provision
```

The password is never committed. The script also revokes `CONNECT` from `PUBLIC` on the app database and on `postgres` and `template1`, so the app role cannot reach another database; if the cluster is shared with other applications, review that before running it. `mix test`, `mix quality_check` and `mix ecto.setup` provision automatically.

Verify (non-zero exit on any deviation; the DDL probes are rolled back):

```
mix cash_lens.db.verify_role
```

#### How the current user reaches PostgreSQL

`CashLens.Repo` is the single choke point (see its moduledoc). A process acts for a user pinned with `Repo.put_current_user_id/1` (done by `CashLensWeb.UserAuth`: the `:browser` and `:api` pipelines per request, the LiveView `on_mount` per socket) or `Repo.with_user/2`. While a user is pinned every Repo operation runs in a transaction that starts with `set_config('app.current_user_id', id, true)`; the setting is transaction-local, so it cannot leak to the next checkout of a pooled connection (`rls_test.exs` proves it on a one-connection pool). Background code pins the operator (`CashLens.Ownership.pin_operator!/0`): Oban workers, mix tasks, seeds. Not wrapped: raw `Repo.query/3` (use `Repo.scoped_query/2`) and `Repo.stream/2`. A new `Task` or process starts with no user and sees nothing until it pins one.

Every new table with a `user_id` needs RLS, a policy and a grant in its migration (`docs/migration-checklist.md`); `rls_test.exs` fails when a table with a `user_id` column is neither covered nor a documented exception (`user_tokens` and `login_attempts`, which are read before anyone is logged in).

### TLS to the database

`config/runtime.exs` (prod) sets, for both repos, `ssl: true` with `ssl_opts`: `verify: :verify_peer`, `server_name_indication` and the hostname check derived from the host in the URL, and the CA from `DATABASE_CA_CERT_PATH` (a PEM file) or, when that is unset, the system store (`:public_key.cacerts_get/0`). Postgrex logs a deprecation warning for `ssl_opts`; the explicit keyword is kept because the contract is `ssl: true` plus `verify: :verify_peer`. Dev and test connect without TLS.

### Encrypted backups

```
BACKUP_AGE_RECIPIENT=age1... scripts/backup.sh
```

Needs `pg_dump` and [`age`](https://github.com/FiloSottile/age). Writes `backups/cash_lens_backup_<UTC>.dump.age` (mode 600). The plaintext dump is never on disk: `pg_dump` pipes straight into `age`, so a failure at any step leaves no file. The script aborts, non-zero, when `BACKUP_AGE_RECIPIENT` is unset. Keep the private key (`age-keygen`) off the database host.

Retention, enforced by the script after each backup from the UTC date in the file name: **7 daily** (younger than 7 days), **4 weekly** (Sunday backups younger than 28 days), **6 monthly** (backups of the 1st younger than 183 days). Other files in `backups/` are left alone.

Restore, and rehearse it into a scratch database before you need it:

```
age -d -i key.txt backups/cash_lens_backup_X.dump.age | pg_restore -d "$SCRATCH_DB_URL" --clean --if-exists --no-owner
```

`backups/` is git-ignored. The older ad hoc `backups/*.dump` files are **plaintext**: encrypt them (`age -r "$BACKUP_AGE_RECIPIENT" -o f.dump.age f.dump`) or delete them. The script does not touch them.

Out of scope: off-site transport of the backups, key rotation.
