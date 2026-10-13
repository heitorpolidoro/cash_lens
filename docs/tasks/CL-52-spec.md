# CL-52 — Application security review and hardening

## Scope
Part 4 of the CL-20 split. Reviews and hardens the auth surface added by CL-49 before public launch. Each item is first audited against the current code, because several are partly in place: `protect_from_forgery` and `put_secure_browser_headers` are in the `:browser` pipeline, `force_ssl` is in `config/prod.exs`, the import drop already has `accept` and `max_file_size`, and the user schema already enforces a 12-character minimum. The task closes the remaining gaps and pins each control with a test or config assertion.

Not covered: per-user data scoping, email confirmation, password reset, MFA, WAF or infrastructure controls, and the dev-only dashboard scope.

## Approach
Behavior
- **CSRF**: every browser-pipeline POST/PUT/PATCH/DELETE without a valid token is rejected with 403. Tests prove it for register, log_in and log_out. If a browser route is found outside `:browser`, or the session-based `:api` scope accepts unsafe verbs without a token, it is fixed or the exception documented.
- **Session cookie**: the endpoint session options carry `http_only: true`, `same_site: "Lax"` and, in prod only, `secure: true`, driven by config rather than hardcoded. Signing salts (session and LiveView) move out of source into config, and an `encryption_salt` is added so the cookie is encrypted. The session options live under a config key (`config :cash_lens, CashLensWeb.Endpoint, session_options: [...]`) that `endpoint.ex` reads at compile time; the test does not run in the prod env, so it evaluates the config files for prod with `Config.Reader.read!/2` (`env: :prod`) and asserts the `session_options` key holds `secure: true`, `http_only: true` and `same_site: "Lax"`.
- **Rate limiting**: a plug (ETS-backed, no new infrastructure; `plug_attack` or `hammer` is acceptable) limits `POST /users/log_in` and `POST /users/register` per client IP, and log_in additionally per submitted email. Defaults: 5 attempts per minute for log_in, 5 per hour for register. Over the limit answers 429 with a `retry-after` header. Client IP honours `x-forwarded-for` only in prod, behind the proxy, configured explicitly. Test config uses high limits by default; the rate-limit tests set low limits and reset state between tests.
- **Password policy**: sign-up rejects passwords in a bundled common-password list (a repo file, compared case-insensitively) and passwords equal to the email or its local part. Min 12 and max 72 (bcrypt byte limit, counted in bytes) are kept. Errors are changeset errors on `:password`, rendered on the sign-up form. Log-in is not subject to the policy.
- **Headers and TLS**: browser responses carry a `content-security-policy` (`default-src 'self'`, no `unsafe-eval`, `frame-ancestors 'none'`, `base-uri 'self'`, `form-action 'self'`, same-origin `connect-src` for the LiveView websocket), plus `x-content-type-options`, `referrer-policy` and a `permissions-policy`. The developer audits inline scripts/styles and CDN assets in the root layout and either self-hosts or allow-lists them; any remaining inline script uses a per-request nonce, not `unsafe-inline`. Prod `force_ssl` sets `hsts: true` explicitly with a long max-age and keeps `rewrite_on: [:x_forwarded_proto]`. The socket `check_origin` is set to the prod host in `runtime.exs`.
- **Secrets**: audit confirms every production secret (`SECRET_KEY_BASE`, `DATABASE_URL`, any API keys) is read in `config/runtime.exs` from env and raises when missing. Committed config may keep only dev/test placeholders; a test asserts `config/prod.exs` and `config/config.exs` contain no secret or credential literal, and a second test evaluates `config/runtime.exs` with `Config.Reader.read!/2` (`env: :prod`) with `SECRET_KEY_BASE` and `DATABASE_URL` each unset in turn (env restored afterwards, test is `async: false`) and asserts it raises. The result is documented.
- **Upload validation**: the import LiveView validates extension (allow-list `.csv .pdf .ofx .txt`), size (10 MB cap kept) and content: `.pdf` must start with `%PDF`; csv/ofx/txt must be valid text with no NUL bytes. The client filename is never used as a path; it is only a sanitized label. A rejected upload shows an error on the import screen and nothing is ingested. Validation runs server-side in the consume step so a crafted client cannot bypass `accept`.
- **Dependency and static analysis**: add `mix_audit` and `sobelow` as dev/test-only deps, a `.sobelow-conf`, and a `mix security` alias running `deps.audit` and `sobelow`. Fix every high-confidence finding, or record each exception (`.sobelow-skips` and `docs/security.md`) with a one-line justification. Vulnerable dependencies are upgraded or documented. Wiring into CI is done if the shared workflow allows it, otherwise noted as follow-up.
- **Documentation**: `docs/security.md` records each control, its config key, how it is tested, and accepted exceptions; AGENTS.md links to it.

Files touched
- `lib/cash_lens_web/endpoint.ex`: session options (flags, salts from config), socket `check_origin`.
- `config/config.exs`, `config/prod.exs`, `config/runtime.exs`, `config/test.exs`: salts, secure cookie in prod, HSTS, rate-limit and origin settings.
- `lib/cash_lens_web/plugs/rate_limit.ex` (new) and `lib/cash_lens_web/router.ex`: limiter on log_in and register POSTs; CSP and secure headers on `:browser`.
- `lib/cash_lens_web/components/layouts/root.html.heex` (and any template with inline script): nonce or self-hosted assets.
- `lib/cash_lens/users/user.ex`, `priv/common_passwords.txt` (new): password policy.
- `lib/cash_lens_web/live/import_live/index.ex` (and the Ingestor entry point if needed): upload content validation and error display.
- `mix.exs`, `mix.lock`, `.sobelow-conf`, `.sobelow-skips` if needed: audit tooling and alias.
- `docs/security.md` (new), `AGENTS.md`: documentation.

Test criteria (named tests under `mix test`)
- `test/cash_lens_web/security_headers_test.exs`: GET of the login page returns the CSP (with `frame-ancestors 'none'`, no `unsafe-eval`) and the other secure headers; POSTs to register, log_in and log_out without a CSRF token return 403.
- `test/cash_lens_web/endpoint_config_test.exs`: prod config (read via `Config.Reader.read!/2` with `env: :prod`) has `session_options` containing `secure: true`, `http_only: true`, `same_site: "Lax"`; prod endpoint config has `force_ssl` with `hsts: true`; `config/prod.exs` and `config/config.exs` contain no secret literal; evaluating `config/runtime.exs` for prod raises when `SECRET_KEY_BASE` is unset and when `DATABASE_URL` is unset.
- `test/cash_lens_web/plugs/rate_limit_test.exs`: with the limit set to N, attempts 1..N pass and attempt N+1 on log_in and on register returns 429 with `retry-after`; a different IP is unaffected.
- `test/cash_lens/users_test.exs`: a common password, the email local part and an 11-character password are rejected with an error on `:password`; a strong 12+ character password is accepted. A sign-up controller test shows the error on the form.
- `test/cash_lens_web/live/import_live_upload_test.exs`: a disallowed extension, an over-10 MB file, a `.pdf` without `%PDF`, and a csv containing NUL bytes are rejected with a visible error and no ingestion; a valid csv is accepted.
- PR gate: `mix security` output with no unresolved high findings; full `mix test` stays green.

## Expected Results
- [ ] Browser POSTs to `/users/register`, `/users/log_in` and `/users/log_out` without a CSRF token answer 403 (named test).
- [ ] Evaluating the prod config with `Config.Reader.read!/2` (`env: :prod`) yields `session_options` with `secure: true`, `http_only: true` and `same_site: "Lax"` (named test).
- [ ] The (limit+1)th `POST /users/log_in` and `POST /users/register` from one IP within the window answers 429 with a `retry-after` header.
- [ ] Sign-up rejects common passwords, a password equal to the email local part, and passwords under 12 characters with a `:password` validation error.
- [ ] Browser responses carry a Content-Security-Policy (no `unsafe-eval`, `frame-ancestors 'none'`) and `x-content-type-options`, `referrer-policy` and `permissions-policy` headers.
- [ ] Prod config sets `force_ssl` with `hsts: true` (named test).
- [ ] `config/prod.exs` and `config/config.exs` contain no secret or credential literals (named test).
- [ ] Evaluating `config/runtime.exs` for prod raises when `SECRET_KEY_BASE` is unset and when `DATABASE_URL` is unset (named test).
- [ ] An import upload with a disallowed extension, over 10 MB, or content not matching its type is rejected with a visible error and nothing is ingested.
- [ ] `mix deps.audit` and `mix sobelow` report no unresolved high findings.
- [ ] Each accepted `deps.audit`/`sobelow` exception is listed with a justification in `docs/security.md`.

## Out of Scope
Per-user data scoping, MFA, password reset and email flows, account lockout UI, infrastructure hardening (reverse proxy, firewall), dev dashboard routes.
