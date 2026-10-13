# CL-56 — Scope Accounts and Categories by the current user

## Scope
Part 2 of the CL-51 split (see `docs/tasks/CL-51-spec.md`, "Convention" and step 2). Builds on CL-55 (`Ownership.scope/2`, `Ownership.validate_owned/3`, user-aware fixtures, `cross_tenant` helper). After this task the `Accounts` and `Categories` contexts, their LiveViews and their JSON controllers name the owner on every call and never read or change another user's rows.

Not in scope: scoping of other contexts (Accounting, Transactions, Installments, CreditCards, Forecast, Imports and their LiveViews/workers/mix tasks, CL-51 parts 3-8), removal of the Repo insert override / `Ownership.assign/1` / `:auto_create_owner`, the scoping audit test, per-user uniqueness (slug, bank+name stay global), the `AGENTS.md` update.

## Approach

### Behavior
- **Signatures.** Every public `Accounts` and `Categories` function that touches rows takes `%CashLens.Users.User{}` first and filters through `Ownership.scope/2` (no hand-written `user_id` predicate): all `list_*`, `get_*`, `get_total_balance`, `get_accounts_by_names`, `find_accounts_by_bank_and_name`, `get_category_by_slug`, `get_category_ids_with_children`, `keyword_conflicts_for`, `reorder_accounts`, `add_keyword`, and the writes. Pure functions stay as they are: `Accounts.move/3`, `Categories.group_by_parent/1`, `keyword_conflicts/1` (it works on the list it is given; its default list becomes `keyword_conflicts(user, categories)`-style or requires the list), and `change_account`/`change_category` (they take a record whose `user_id` is already set; a new record is built by the caller with the user's id).
- **Reads.** `get_account!`/`get_category!` raise `Ecto.NoResultsError` for another user's id; `get_account_by_name` and `get_category_by_slug` return `nil`. `get_category_ids_with_children` scopes both the anchor and the recursive step of the CTE, so it never walks into another user's categories. `list_categories` links parents only among the user's rows.
- **Writes.** `create_account(user, attrs)` / `create_category(user, attrs)` set `user_id` from the user on the struct; a `"user_id"` key in `attrs` is ignored, never cast. `update_*(user, record, attrs)` and `delete_*(user, record)` re-fetch by `record.id` via `scope/2` and return `{:error, :not_found}` when the row is not the user's, leaving it unchanged. `reorder_accounts(user, ids)` only updates that user's rows (foreign ids are skipped). `delete_account` deletes only that user's balances and transactions of the account, then the account. `add_keyword(user, category, kw)` follows the same not-found rule.
- **Foreign keys.** `Category.changeset` calls `Ownership.validate_owned(:parent_id, Category)`, so a `parent_id` owned by another user gives a changeset error on `parent_id` on create and on update. (`Account` has no caller-supplied foreign key.)
- **PubSub.** The `"categories"` topic currently broadcasts every user's category events to every subscriber. It becomes per user (`"categories:<user_id>"`), and `TransactionLive.Index` subscribes using its `current_user`, so a user never receives another's category events.
- **Controllers.** `Api.AccountController` and `Api.CategoryController` read `conn.assigns.current_user` and pass it in. Show/update/delete of another user's id answer `404` (existing `not_found` path, plus mapping `{:error, :not_found}`). Create sets the owner from the user; list returns only that user's rows.
- **LiveViews.** `AccountLive.{Index,Show,FormComponent}` and `CategoryLive.{Index,Show,FormComponent}` use `socket.assigns.current_user` everywhere, including `handle_event`, `handle_params`, `handle_info`; form components receive `current_user` as an assign from their parent. `AccountLive.Show` (`/accounts/:id`), `AccountLive.Index` edit (`/accounts/:id/edit`) and `CategoryLive.Show` (`/categories/:id`) redirect to `/accounts` or `/categories` with an error flash when the id is not the user's, never rendering its data. Event ids (delete, toggle closed, reorder, move, type change, edit) resolve through the scoped getters, so a forged id from another user is a no-op with an error flash.
- **Callers outside these contexts.** Code not yet converted (Transactions, TransferMatcher, TransferRuleApplier, Forecast, Imports, CreditCards and Matcher, Accounting and BalanceAdjuster, DirectoryImporter, `PageController`, `BalanceLive`, `TransactionLive`, `ReimbursementLive`, `TransferLive`, `AutomationLive`, `CreditCardStatementLive`, mix task `migrate_credit_card_transfers`) must keep compiling and passing. Web-layer callers use `current_user` from the socket/conn assigns directly. Contexts, workers and mix tasks that have no user yet obtain one through a temporary shim, `Ownership.current_user!/0`, which loads the `%User{}` of the process-pinned user via the existing `current_user_id!/0` and carries the comment `# TRANSITIONAL: removed when CL-51 converts the caller`. The shim is the only new production code outside the two contexts, their controllers and LiveViews, and is deleted in CL-51's last part.

### Files touched
- `lib/cash_lens/accounts.ex`, `lib/cash_lens/categories.ex`: user first argument, scoping, owner set on create, `{:error, :not_found}` on foreign records, per-user PubSub topic.
- `lib/cash_lens/categories/category.ex`: `validate_owned(:parent_id, Category)` in the changeset.
- `lib/cash_lens/ownership.ex`: transitional `current_user!/0`.
- `lib/cash_lens_web/controllers/api/{account,category}_controller.ex`: pass `current_user`, 404 mapping.
- `lib/cash_lens_web/live/account_live/{index,show,form_component}.ex`, `lib/cash_lens_web/live/category_live/{index,show,form_component}.ex`: pass user, redirect with flash, forged-id no-op.
- `lib/cash_lens_web/live/transaction_live/{index,quick_category_component}.ex`: pass user to `Categories`/`Accounts` calls, subscribe to the per-user topic.
- Mechanical call-site updates (pass user or shim, no behavior change) in the other files listed under "Callers outside these contexts" and any other file the compiler flags.
- Existing tests and `test/support/fixtures/{accounts,categories}_fixtures.ex` updated to the new signatures.
- New: `test/cash_lens/accounts_tenancy_test.exs`, `test/cash_lens/categories_tenancy_test.exs`, `test/cash_lens_web/controllers/api/{account,category}_controller_tenancy_test.exs`; LiveView cross-tenant cases appended to `test/cash_lens_web/live/account_live_test.exs` and `category_live_test.exs`.

### Test criteria
- Context tenancy tests (via `cross_tenant`): with A owning rows, B's `list_*` is `[]`, `get_*!` raises `Ecto.NoResultsError`, `get_*`/`get_category_by_slug` return `nil`, `get_category_ids_with_children(b, a_category.id)` is `[]`, `update_*`/`delete_*` return `{:error, :not_found}`, `reorder_accounts` leaves A's positions untouched, and A's rows are unchanged in the DB. B creating or updating a category with A's category as `parent_id` returns a changeset error on `parent_id`. B creating a record with `"user_id" => a.id` still owns it as B.
- A subscriber on B's category topic receives nothing when A creates a category.
- API, logged in as B: `GET/PUT/DELETE /api/accounts/:id` and `/api/categories/:id` for A's record return `404` and leave it unchanged; list endpoints return only B's rows.
- LiveView, logged in as B: `/accounts/:id`, `/accounts/:id/edit`, `/categories/:id` for A's record redirect to the list route with a flash and the output never contains A's name; list pages show only B's rows; a forged delete (and toggle/reorder/type) event carrying A's id is a no-op with an error flash and A's row still exists.
- Full `mix test` and `mix precommit` pass.

## Expected Results
- [ ] `Accounts` and `Categories` public row-touching functions take the user first, filter via `Ownership.scope/2`, and set `user_id` on create, with every caller updated so `mix test` and `mix precommit` pass.
- [ ] `accounts_tenancy_test.exs` and `categories_tenancy_test.exs` prove user B gets empty lists, `nil` or `Ecto.NoResultsError` on get, `{:error, :not_found}` on update and delete, and user A's rows stay unchanged.
- [ ] Creating or updating a category with a `parent_id` owned by another user fails with a changeset error on `parent_id`.
- [ ] `GET/PUT/DELETE /api/accounts/:id` and `/api/categories/:id` for another user's record return `404`, and the list endpoints return only the logged-in user's rows.
- [ ] Visiting `/accounts/:id`, `/accounts/:id/edit` and `/categories/:id` for another user's record redirects to the list route with a flash, and the page does not contain that record's data.
- [ ] Account and category list LiveViews show only the logged-in user's rows, and a forged delete event with another user's id is a no-op with an error flash.

## Out of Scope
- Scoping Accounting, Transactions, Installments, CreditCards, Forecast, Imports, workers, mix tasks, `AdminDatabaseLive` (later CL-51 parts).
- Removing the Repo override, `Ownership.assign/1`, `:auto_create_owner`, and the transitional `current_user!/0`.
- Per-user uniqueness of slugs or account names.
