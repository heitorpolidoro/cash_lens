# CL-49 — Add users, authentication and enabled-user gate

## Scope
Part 1 of the CL-20 split. Adds a `users` table, an `Accounts`-independent `CashLens.Users` context (name chosen to avoid clashing with the existing bank-account `CashLens.Accounts`), sign-up, login, logout, session handling, and an auth-required plus enabled-gate on every app route. A newly registered user has `enabled = false`; the operator flips it manually in the DB. The app has no per-user data ownership yet.

Not covered: scoping data to a user (tenant ownership), email confirmation, password reset, remember-me, admin UI to enable users, rate limiting, mailer flows, and authenticating the `/api` JSON scope beyond what is stated below.

## Approach
Behavior
- `users` table: `email` (citext, unique, NOT NULL), `hashed_password` (NOT NULL), `enabled` (boolean, NOT NULL, default false), timestamps. Migration enables the `citext` extension if absent.
- Passwords are hashed with a password-hashing library added to `mix.exs` (bcrypt_elixir preferred; `pbkdf2_elixir` acceptable if native compilation is a problem). The plaintext lives only in a virtual field and is never persisted. Email is validated (format, max length) and password has a minimum length (12). Test config lowers the hashing cost.
- Routes (browser scope, unauthenticated): `GET/POST /users/register`, `GET/POST /users/log_in`, `DELETE /users/log_out`. Sign-up creates the user disabled; it does not log them in as an enabled user and lands on the pending-approval page. Login failures show a generic "invalid email or password" message and do not reveal whether the email exists.
- Login stores the user's id in the session and renews the session id (fixation protection); logout clears the whole session and redirects to the login page. A session whose user no longer exists is treated as logged out.
- Plugs in a new `CashLensWeb.UserAuth` module: `fetch_current_user` (added to the `:browser` pipeline), `require_authenticated_user` (redirect 302 to `/users/log_in` when none), `require_enabled_user` (a logged-in but disabled user is redirected to `/users/pending`, which renders the pending-approval message and a log-out button), and `redirect_if_authenticated` for the register/login pages. Enabled status is read from the DB on each request, so enabling a user in the DB takes effect without re-login.
- The LiveView `:default` live_session and every non-public controller route (`/`, `/credit_card_links`, `/admin/*` redirects) sit behind both gates; the live_session also uses an `on_mount` hook that re-checks the user so socket reconnects of a logged-out or disabled session are rejected. Public routes: register, login, pending page, the Chrome devtools well-known route. The `/api` scope also requires an authenticated enabled user (session-based; unauthenticated returns 401 JSON, not a redirect). The dev-only dashboard scope is out of scope.
- Existing tests must keep passing: `ConnCase` gains `register_and_log_in_user/1` (creates an enabled user, puts the session) and the existing web/LiveView/API tests that hit protected routes use it.
- AGENTS.md "no login/auth layer" statements are updated, and the file map lists the new modules.

Files touched
- `mix.exs` / `mix.lock`: password-hashing dependency.
- `priv/repo/migrations/<ts>_create_users.exs`: citext extension, users table, unique index on email.
- `lib/cash_lens/users.ex`, `lib/cash_lens/users/user.ex`: context (register, get by email+password, get by id) and schema/changesets.
- `lib/cash_lens_web/user_auth.ex`: plugs and on_mount hook.
- `lib/cash_lens_web/controllers/user_registration_controller.ex`, `user_session_controller.ex`, `user_pending_controller.ex` plus HTML modules/templates (register, login, pending).
- `lib/cash_lens_web/router.ex`: pipelines and scopes described above.
- `config/test.exs`: low hashing cost.
- `test/support/conn_case.ex`, `test/support/fixtures/users_fixtures.ex`: login helper and fixture; existing tests updated to log in.
- `AGENTS.md`: doc update.

Test criteria (named tests under `mix test`)
- `test/cash_lens/users_test.exs`: registration stores a hashed password and `enabled == false`; duplicate email differing only by case is rejected; invalid email/short password rejected; the DB column rejects NULL `enabled` and defaults to false.
- `test/cash_lens_web/controllers/user_registration_controller_test.exs`: valid POST creates a disabled user; invalid POST re-renders with errors.
- `test/cash_lens_web/controllers/user_session_controller_test.exs`: enabled user logs in and is redirected to `/`; wrong password shows the generic error and no session; logout clears the session and a request replaying the old session cookie is redirected to login.
- `test/cash_lens_web/user_auth_test.exs`: logged-out request to `/`, `/accounts` (LiveView) and a sample route is 302 to `/users/log_in`; disabled logged-in user is redirected to `/users/pending` and sees the pending-approval message and never the app page; enabling that user in the DB lets the next request through; `/api/accounts` returns 401 when logged out.
- Full existing suite stays green.

## Expected Results
- [ ] A migration creates `users` with a unique case-insensitive `email` and an `enabled` boolean that is NOT NULL and defaults to false (asserted in `users_test.exs`).
- [ ] `POST /users/register` with valid params creates a user with `enabled == false` and a hashed password that differs from the plaintext.
- [ ] `POST /users/log_in` with valid credentials of an enabled user starts a session and redirects to `/`.
- [ ] A logged-out request to `/` and to a LiveView route such as `/accounts` answers 302 to `/users/log_in`.
- [ ] A logged-in user with `enabled == false` is redirected from app routes to `/users/pending`, which shows a pending-approval message.
- [ ] `DELETE /users/log_out` clears the session, and replaying the previous session cookie on `/` redirects to the login page.
- [ ] The named sign-up, login, logout and enabled-gate tests pass, and the full `mix test` suite stays green.

## Out of Scope
Per-user data scoping, email confirmation, password reset, admin UI for enabling users, rate limiting, `/dev` routes.
