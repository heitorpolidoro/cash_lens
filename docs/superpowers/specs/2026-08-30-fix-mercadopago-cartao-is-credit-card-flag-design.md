# CL-1 — Corrigir is_credit_card=false na conta Mercado Pago Cartão de Crédito

## Scope

Fix one bad data row: the account with id `de7aab37-2011-42d2-a2e7-5e21c6a5e0b7`
(name "Cartão de Crédito", bank "Mercado Pago") has `is_credit_card = false` in
the `accounts` table, when it is in fact a genuine credit-card account (its
Pluggy link reports a card-bill `pluggy_balance` of R$2102.20). Because of the
wrong flag, `CashLensWeb.PageController.home/2` includes it in the dashboard's
"Saldo Atual" total and in the account listing, both of which already exclude
`is_credit_card = true` accounts correctly for every other credit card in the
system.

This task does **not** change any application code, query, or exclusion logic
in `page_controller.ex` — that logic is already correct and is proven correct
by every other credit-card account already being excluded properly. This is a
data-only correction.

Verified before writing this spec, via direct `psql` query against the dev DB
(`localhost:5431/cash_lens`):

```
id: de7aab37-2011-42d2-a2e7-5e21c6a5e0b7
name: Cartão de Crédito
bank: Mercado Pago
is_credit_card: f
is_closed: f
pluggy_account_links.pluggy_balance: 2102.2
```

The current "Saldo Atual" total for eligible (non-credit-card, non-closed)
accounts includes this account's `pluggy_balance` of R$2,102.20. Removing it
exactly accounts for the operator-observed drop from ~R$48,362.16 to
~R$46,259.96 (48362.16 − 46259.96 = 2102.20).

## Approach

**Delivery mechanism: UI edit, not a migration.**

`lib/cash_lens_web/live/account_live/form.ex` already renders an editable
`is_credit_card` checkbox (labeled "Cartão de crédito?") wired to the existing
`Accounts` context update path (`AccountLive.Form`'s `save` event →
`Accounts.update_account/2` or equivalent). No code change, and no new LiveView
field, is needed — the form already supports exactly this correction.

Rationale for choosing the UI-edit path over a data-fixing Ecto migration:
- CashLens is explicitly a local-only, single-user app (see
  `docs/superpowers/specs/` and `AGENTS.md`) with no multi-environment
  reproducibility requirement — there's no second deployment that would ever
  need this fix replayed.
- `priv/repo/migrations/` has no existing precedent of one-off data-correcting
  migrations (checked: no migration in the directory contains a raw
  `UPDATE accounts` or similar row-level data fix; existing `execute(...)`
  calls in migrations are schema DDL, e.g. `add_source_to_transactions.exs`).
  Introducing that pattern here for a single boolean flip on one row would add
  process weight the project doesn't otherwise use.
- The feature to fix exactly this kind of mistake (an account's
  `is_credit_card` flag) already exists in the product and is reachable by
  the account's own owner in a few seconds.

**Steps to perform the fix:**
1. Navigate to `/accounts` (Accounts LiveView index).
2. Open the edit form at `/accounts/de7aab37-2011-42d2-a2e7-5e21c6a5e0b7/edit`
   for "Cartão de Crédito" / Mercado Pago.
3. Check the "Cartão de crédito?" checkbox.
4. Save.

Equivalent SQL, for reference/verification only (not to be run as a migration):
```sql
UPDATE accounts SET is_credit_card = true
WHERE id = 'de7aab37-2011-42d2-a2e7-5e21c6a5e0b7';
```

**Test coverage: none added.** This is a one-off, idempotent data correction
to a single row through an already-tested, already-shipped UI path
(`AccountLive.Form`'s edit/save flow and `page_controller.ex`'s credit-card
exclusion logic both already have test coverage from prior work). Adding a
new test whose only assertion is "this specific row's boolean is now true"
is boilerplate with no regression-prevention value — nothing in the code
changes, so there is nothing new for a test to protect against regressing.
If a future account is imported with a wrong `is_credit_card` flag, that is
a new occurrence of the same class of data-entry issue, not something this
task's test could have caught.

## Expected Results

- [ ] `SELECT is_credit_card FROM accounts WHERE id = 'de7aab37-2011-42d2-a2e7-5e21c6a5e0b7'` returns `true`.
- [ ] `GET /` (dashboard home) no longer includes this account in the "Saldo Atual" total; the total drops from ~R$48,362.16 to ~R$46,259.96 (a decrease of R$2,102.20, matching the account's `pluggy_balance`).
- [ ] `GET /` no longer lists "Cartão de Crédito" (Mercado Pago) in the accounts section of the dashboard — it is excluded the same way every other `is_credit_card = true` account already is.
- [ ] No application code, migration, or test file is modified as part of this fix (data-only correction via the existing `/accounts/:id/edit` UI).

## Out of Scope

- Any change to `page_controller.ex`'s balance/exclusion logic (already correct).
- A migration or seed/fixture change (this is a single dev-environment data
  correction, not a schema or repeatable-data change).
- Auditing other accounts for similarly wrong flags (not requested; out of
  scope for this task).
