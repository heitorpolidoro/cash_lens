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
| Secrets only from the environment | `SECRET_KEY_BASE` and `DATABASE_URL` are read in `config/runtime.exs` and raise when missing. `config/prod.exs` and `config/config.exs` hold no secret (salts are not secrets: they only namespace key derivation from `secret_key_base`) | `endpoint_config_test.exs` (literal scan + runtime evaluation with each variable unset) |
| Upload validation: extension allow-list `.csv .pdf .ofx .txt` (case-insensitive), 10 MB cap, content check (`.pdf` starts with `%PDF`; the others have no NUL or binary control bytes; latin-1 text is accepted). The client file name is only a sanitized label | `CashLens.Imports.validate_drop/2`, called in the consume step of `ImportLive.Index`, so a crafted client cannot bypass `accept` | `test/cash_lens_web/live/import_live_upload_test.exs` |

## Audit result and secrets inventory

Production secrets: `SECRET_KEY_BASE` and `DATABASE_URL` (both required, raise when absent). The Pluggy integration was dropped (see the `drop_pluggy` migration), so there are no API keys. Dev/test placeholders live in `config/dev.exs` and `config/test.exs` only.

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
