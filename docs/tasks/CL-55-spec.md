# CL-55 — Add ownership scoping foundation and tenancy test helpers

## Scope
Part 1 of the CL-51 split (see `docs/tasks/CL-51-spec.md`, "Convention" and implementation step 1). It adds the shared primitives later parts use: `Ownership.scope/2`, `Ownership.validate_owned/3`, `Ownership.operator_user!/0`, user-aware test fixtures and a shared `cross_tenant` test helper.

It is purely additive. No context, LiveView, controller, worker or mix task changes signature or behavior. The Repo pin API (`put_current_user_id/1`, `with_user/2`) stays because CL-53 row-level security depends on it. `assign/1`, `current_user_id!/0`, the `Repo.insert`/`insert!` override and `:auto_create_owner` are deliberately left in place; CL-51's last part removes them.

## Approach
**Behavior, `lib/cash_lens/ownership.ex`**
- `scope(queryable, %CashLens.Users.User{} = user)` returns the queryable with `where: x.user_id == ^user.id` (a binding-agnostic first-binding filter, works on schema modules and existing queries). It does not touch the Repo or the pinned user.
- `validate_owned(changeset, field, schema)` reads the changeset's `user_id` (`get_field`). When `field` has a change (non-nil), it checks that a row of `schema` with that id exists and has that `user_id`; otherwise it adds an error on `field` (message "does not exist", same style as `foreign_key_constraint`). Returns the changeset unchanged when `field` has no change or the id is owned. If the changeset has no `user_id`, any non-nil referenced id is an error (fail closed). The existence lookup runs under the changeset owner (via `Repo.with_user/2`), so it also works when RLS is enforced and nothing is pinned.
- `operator_user!/0` returns the `%User{}` named by `CASH_LENS_OPERATOR_EMAIL`; if the variable is unset or empty, the only user in the table. It raises when the email matches no user, when several users exist and the variable is unset, and when no user exists. It never creates a user (unlike the legacy private fallback, which keeps `:auto_create_owner` behavior untouched). It is documented as for mix tasks and seeds only.

**Behavior, test support**
- Each fixture in `test/support/fixtures/*.ex` (`account`, `balance`, `category`, `credit_cards`, `forecast`, `transactions` fixtures) accepts an optional `:user` key (`%User{}`) in `attrs`. The fixture is created acting as that user (`Repo.with_user/2`), and the key is not passed on as a schema attribute. Fixtures that build dependencies (account for a balance, category for a recurring item) create them for the same user.
- Default when `:user` is absent: the user already pinned for the test process (DataCase creates and pins a fresh user per test, so existing tests keep working unchanged); if no user is pinned (`@tag :no_current_user`), a fresh `UsersFixtures.user_fixture()` is used. This keeps `mix test` unchanged while letting new tests pass an explicit user.
- New `test/support/tenancy_case.ex` (or `tenancy.ex`) module `CashLens.Tenancy` with `cross_tenant/1` (name may be `cross_tenant/2` with options): it creates two fresh users A and B and returns `%{a: user_a, b: user_b}`; with a function argument it calls `fun.(user_a, user_b)` and returns its result. Intended use: build rows as A, call a context function as B, assert empty/not-found and unchanged rows. It leaves the test process pinned as it found it. It is importable from `DataCase`/`ConnCase` via a `use`/`import` line so later tests need no extra setup.

**Files touched**
- `lib/cash_lens/ownership.ex`: add `scope/2`, `validate_owned/3`, `operator_user!/0` with docs.
- `test/support/fixtures/{accounts,accounting,categories,credit_cards,forecast,transactions}_fixtures.ex`: optional `:user`. `users_fixtures.ex` (it creates the owner itself) and `fixtures/files/` (static data) are intentionally untouched.
- `test/support/tenancy.ex` (new): `cross_tenant` helper; `test/support/data_case.ex` and `conn_case.ex`: import it.
- `test/cash_lens/ownership_test.exs` (new): unit tests below. (`user_ownership_test.exs` exists; extend it instead if it already covers `Ownership`.)

**Test criteria**
- `scope/2` (must fail if the `where` is removed, because RLS alone would hide rows when pinned to the queried user): (1) with A and B each owning accounts and the process pinned as A (`with_user(a, ...)`, so RLS shows A's rows), `Account |> scope(b) |> Repo.all()` returns `[]` while the unscoped `Repo.all(Account)` returns A's rows, and `scope(a)` returns exactly A's rows; (2) `Repo.to_sql(:all, Account |> scope(b))` yields SQL containing a `user_id` equality whose parameter list is `[b.id]`, and an existing query with its own `where` keeps that filter and gains the ownership one.
- `validate_owned/3`: an `account_id` owned by the same user adds no error; one owned by another user adds an error on `:account_id`; no change adds none.
- `operator_user!/0`: env set to an existing email returns that user; env set to an unknown email raises; env unset with one user returns it; with zero or several users raises. Tests restore the env var in `on_exit` and run non-async.
- Fixtures: `account_fixture(%{user: b}).user_id == b.id`; with no `:user` it equals the pinned user; `cross_tenant/1` returns two distinct users.
- Existing `test/cash_lens/rls_test.exs` and `user_ownership_test.exs` pass untouched, covering `put_current_user_id/1` and `with_user/2`; full `mix test` is green.

## Expected Results
- [ ] `CashLens.Ownership.scope/2` adds a `user_id == user.id` filter: with the process pinned as A, `scope(b)` returns `[]` while the unscoped query returns A's rows, and the built SQL carries `user_id` with param `b.id`, so removing the `where` fails the tests.
- [ ] `CashLens.Ownership.validate_owned/3` adds an error on the field for another user's id and none for an id of the same user, proven by a unit test.
- [ ] `CashLens.Ownership.operator_user!/0` returns the user from `CASH_LENS_OPERATOR_EMAIL` or the only existing user, and raises otherwise, proven by a unit test.
- [ ] The six domain fixtures (accounts, accounting, categories, credit_cards, forecast, transactions; not `users_fixtures.ex` or `files/`) accept an explicit `:user` that sets the row's `user_id`, and `cross_tenant` returns two distinct users.
- [ ] `CashLens.Repo.put_current_user_id/1` and `with_user/2` still exist and `test/cash_lens/rls_test.exs` passes.
- [ ] `mix test` passes with no changes to production code other than `lib/cash_lens/ownership.ex`.

## Out of Scope
- Changing any context, web, worker or mix-task signature (CL-51 parts 2 to 8).
- Removing `assign/1`, `current_user_id!/0`, the Repo insert override or `:auto_create_owner` (last CL-51 part).
- The scoping audit test and the `AGENTS.md` update.
