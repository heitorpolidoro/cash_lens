# CL-54 — Production readiness: account recovery, audit, health and privacy

## Scope
Part 6 of the CL-20 split. Adds, on top of the CL-49 users/auth layer: email confirmation, password reset, a login audit log, a `/health` endpoint, production error tracking, a privacy (LGPD) notice page, and self-service data export and account deletion.

Data ownership caveat: CL-49 left domain data (accounts, transactions, ...) global, with no `user_id`. Export and deletion therefore operate on a single registry of user-owned schemas. Today it contains the user's own rows (user, confirmation/reset tokens, login audit entries); any table that gains a `user_id` in the tenant-ownership work must be added to that registry. Global domain data is never exported or deleted by this task.

Not covered: rate limiting/lockout, admin UI, remember-me, changing email or password while logged in, MFA, scheduled/async export, a real mail provider account, choosing an error-tracking vendor account (DSN is supplied by env).

## Approach
Behavior
- Email confirmation: `users` gains `confirmed_at`. Registration sends a confirmation email (Swoosh, `CashLens.Mailer`) containing a link to `GET /users/confirm/:token`. Login for a user with `confirmed_at` nil is refused with a message that says to confirm the email (without breaking CL-49's generic wrong-credentials message for bad passwords), and a "resend confirmation" action exists. Visiting a valid link sets `confirmed_at`. Existing users are backfilled as confirmed by the migration. The `enabled` gate from CL-49 is independent and unchanged.
- Tokens: a `user_tokens` table (user_id with on_delete delete_all, context `confirm`/`reset_password`, sent_to email, hashed token, inserted_at). Only the SHA-256 hash is stored; the raw token appears only in the emailed link. Confirm tokens expire after 7 days, reset tokens after 1 hour. A token is deleted when used; using it again, an expired one, or a tampered one fails with a generic error.
- Password reset: `GET/POST /users/reset_password` (request form; always answers with the same message whether or not the email exists) and `GET/PUT /users/reset_password/:token`. A successful reset applies the CL-49 password rules, deletes all of the user's reset tokens, and rotates the session nonce (`Users.rotate_session_nonce/1`) so existing sessions die. Links to these pages are on the login page.
- Login audit: `login_attempts` table (user_id nullable, on_delete nilify, the submitted email, `success` boolean, `ip` text, inserted_at). The session controller writes one row per attempt, success or failure, including unknown emails (user_id nil). IP comes from the connection's remote IP; if the app is behind a proxy, honour the configured trusted-proxy header only when configured. Submitted passwords are never stored.
- Health: `GET /health` is outside the browser/auth pipelines, returns JSON, runs a trivial DB query (`SELECT 1`) with a short timeout, and answers 200 `{"status":"ok"}` when it succeeds and 503 otherwise (including when the query raises or times out). It leaks no internals.
- Error tracking: add Sentry (`sentry` dependency, plus `Sentry.PlugCapture`/`Sentry.PlugContext` in the endpoint and the logger handler) configured only in `config/runtime.exs` for prod from `SENTRY_DSN`; with no DSN, or in dev/test, nothing is sent. The Oban/telemetry-reported job failures are also captured. The `sentry` choice may be swapped for an equivalent by the developer if it needs an HTTP client incompatible with the project; the behavior (unhandled errors reported in prod only) stays.
- Mail in prod: `config/runtime.exs` configures a production Swoosh adapter from env (API key, from address); `Swoosh.ApiClient.Req` is already set in prod.
- Privacy page: public `GET /privacy` (outside the auth gates, static template) describing what data is stored, purpose, retention, the export/delete rights and a contact. Linked from the register and login pages and from the app footer for logged-in users.
- Export: `GET /account/export` (authenticated, enabled) returns a JSON attachment (`content-disposition: attachment`) with every row of every schema in the owned-data registry, with `hashed_password` and token hashes omitted. Another user's rows never appear.
- Delete: `DELETE /account` (authenticated, enabled) requires the current password in the params, deletes all the user's rows in one transaction (registry schemas then the user), clears the session, and redirects to the login page. A wrong password changes nothing. Login audit rows are removed with the user (audit rows for that user are deleted, not retained). A confirmation UI step (typed password plus a warning text) lives on a small account page reachable from the app navigation.

Files touched
- `mix.exs` / `mix.lock`: `sentry` (and its HTTP client if needed).
- `priv/repo/migrations/<ts>_add_confirmation_tokens_and_login_attempts.exs`: `confirmed_at` (backfilled), `user_tokens`, `login_attempts`.
- `lib/cash_lens/users.ex`, `users/user.ex`, new `users/user_token.ex`, `users/user_notifier.ex`: confirm/reset flows, token build/verify, emails.
- new `lib/cash_lens/audit.ex` and `audit/login_attempt.ex`: record and list login attempts.
- new `lib/cash_lens/privacy.ex`: owned-data registry, `export/1`, `delete_account/2`.
- `lib/cash_lens_web/router.ex`: confirm, reset, privacy, health, account export/delete routes.
- `lib/cash_lens_web/controllers/`: user_confirmation, user_reset_password, health, privacy, user_account controllers plus HTML modules/templates; `user_session_controller.ex` (audit write, unconfirmed refusal); register/login templates (privacy and reset links).
- `lib/cash_lens_web/endpoint.ex`, `application.ex`, `config/runtime.exs`, `config/config.exs`: Sentry and prod mailer wiring.
- `test/support/fixtures/users_fixtures.ex`: fixtures create confirmed users so existing tests keep passing.
- `AGENTS.md`: document the new modules, routes and env vars (`SENTRY_DSN`, mail settings).

Test criteria (named tests under `mix test`)
- Confirmation: registering delivers one email (Swoosh test adapter) with a link; an unconfirmed login is refused and creates no session; after using the link the same login succeeds; an expired or reused confirm token fails.
- Reset: request delivers one email for a known email and the same response for an unknown one; the token sets a new password, the old password stops working, a second use of the token fails, an expired token (time-shifted in DB) fails, and a pre-reset session no longer authenticates.
- Audit: a successful login, a wrong password and an unknown email each add one `login_attempts` row with correct `success`, email, a non-empty IP and timestamp; no password text appears in any column.
- Health: 200 with the DB up; 503 when the DB check fails (stubbed/injectable check function); reachable while logged out.
- Error tracking: a config test asserts Sentry is not enabled in test and that runtime config enables it in prod when `SENTRY_DSN` is set; a test with Sentry's test collector asserts an unhandled controller error is captured.
- Privacy: `/privacy` returns 200 logged out; the register and login pages contain a link to it.
- Export/delete: export returns the user's data as an attachment, contains no `hashed_password`, and excludes another user's rows; delete with the right password removes the user, tokens and audit rows and clears the session; with the wrong password nothing is removed.
- Full existing suite stays green.

## Expected Results
- [ ] After `POST /users/register` one confirmation email is delivered, and `POST /users/log_in` for that unconfirmed user creates no session until `GET /users/confirm/:token` is used (asserted in tests).
- [ ] A password-reset token link sets a new password once, and a second use, an expired token, or an unknown token is rejected.
- [ ] Each login attempt, successful or failed, inserts one `login_attempts` row with user (or nil for an unknown email), timestamp and IP.
- [ ] `GET /health` answers 200 with the database reachable and 503 when the database check fails, without login.
- [ ] With `SENTRY_DSN` set in prod config an unhandled error is reported to Sentry, and nothing is sent in test/dev.
- [ ] `GET /privacy` answers 200 logged out and is linked from both the sign-up and login pages.
- [ ] `GET /account/export` returns the user's data as a downloadable file without password hashes, and `DELETE /account` with the correct password removes the user and all their owned rows.

## Out of Scope
Rate limiting or lockout on failed logins, an admin audit viewer, in-session email/password change, MFA, async export jobs, per-user scoping of domain data (the registry is the extension point for that work), selecting and paying for the mail and Sentry accounts.
