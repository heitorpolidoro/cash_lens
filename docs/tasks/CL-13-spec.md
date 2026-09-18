# CL-13 — Redesign the Transfers Center (/transfers) with smart reconciliation and pairing rules

## Scope
Redesign of the Transfers Center (`/transfers`) into a fast reconciliation panel for movements between the user's own accounts. The goal is to keep internal transfers accounting-neutral (outflows must not become expenses, inflows must not become income), offering one-click smart pairing suggestions, tabs split by lifecycle stage, mirror-transaction creation and a quick link to the automatic transfer rules screen.

Includes:
- A single top indicator card — "Pending Pairs": count of transfer transactions whose counterpart has not been confirmed yet.
- Highlighted card for suggested pairs:
  - Algorithm identifies debits and credits of the same amount across different accounts within a short date window (up to 3 days).
  - One-click "Confirm Pair" / "Confirm All" actions, generating the corresponding `transfer_key`.
- Tab split:
  - "Pending Pairing" tab: lists unmatched debits/credits with "Link Manually" and "+ Create Mirror" buttons (creates the matching transaction on the other account when it was never imported).
  - "Reconciled History" tab: lists already-linked pairs showing the flow `[Account A] ➔ [Account B]`, date and amount.
- Manual link modal:
  - Shows the selected transaction and lists statement candidates with the amount difference and the day difference.
- Navigation-only link to `/admin/transfer_rules` in the page header of `/transfers` (the title row of `TransferLive.Index`, not the global app layout/sidebar). It only navigates; it executes no action.
- Move the "Reapply Automatic Rules" action out of `/transfers` and into the transfer rules admin screen (`/admin/transfer_rules`).
- Update and add tests in `test/cash_lens_web/live/transfer_live_test.exs` and `test/cash_lens_web/live/automation_live/transfer_rules_test.exs`.

Explicitly out of scope:
- Changes to the transfer schema structure (`transfer_key` on the `Transaction` model).
- Credit card statement reconciliation (`/statements`).

## Approach
### 1. Behavior
- `/transfers` keeps pointing to `CashLensWeb.TransferLive.Index`.
- The LiveView computes the single "Pending Pairs" indicator and loads automatic suggestions via `Transactions.TransferMatcher`. No "amount moved in the month" and no "neutrality / double-taxation savings" indicator is computed or rendered anywhere on the page.
- Confirming a pair triggers `Transactions.link_transfer_pair/2` and updates the UI through LiveView reactivity.
- Creating a mirror triggers `Transactions.create_mirror_transaction/2`, generating the symmetric transaction on the destination account.
- Tab navigation is handled with `live_patch` and a query parameter (`?tab=pending` vs `?tab=history`).
- The `reapply_rules` event and its button no longer exist in `TransferLive.Index`; the same action (calling `Transactions.reapply_transfer_rules/0` and flashing the number of categorized transactions) is available from `AutomationLive.TransferRules` at `/admin/transfer_rules`.

### 2. Files Touched
- `lib/cash_lens_web/live/transfer_live/index.ex`: restructure the HEEx render (page-header navigation link to `/admin/transfer_rules` as the only header action, single pending-pairs indicator, suggestions block, tabs, flow-oriented table and manual link modal); remove the "Reapply Automatic Rules" button and the `reapply_rules` event handler.
- `lib/cash_lens_web/live/automation_live/transfer_rules.ex`: add the "Reapply Automatic Rules" button and the `reapply_rules` event handler calling `Transactions.reapply_transfer_rules/0`.
- `lib/cash_lens/transactions.ex`: ensure helpers for listing pending transfers and reconciled history.
- `test/cash_lens_web/live/transfer_live_test.exs`: tests for the pending-pairs indicator, suggested pair approval, tab switching, mirror creation, and absence of the reapply action.
- `test/cash_lens_web/live/automation_live/transfer_rules_test.exs`: test that the reapply action runs from the admin screen.

### 3. Test Criteria
- `test/cash_lens_web/live/transfer_live_test.exs` asserts:
  - The "Pending Pairs" indicator renders with the correct count.
  - The rendered page contains no "moved in the month" or "neutrality"/"double taxation" indicator.
  - `/transfers` exposes no `reapply_rules` action (rendering the page contains no such `phx-click`), and its page header keeps only the `/admin/transfer_rules` navigation link.
  - Suggested pairs are displayed and can be confirmed.
  - Tab switching between pending and history works.
  - Mirror transaction creation succeeds.
- `test/cash_lens_web/live/automation_live/transfer_rules_test.exs` asserts that triggering `reapply_rules` on `/admin/transfer_rules` succeeds and shows a result flash.
- `mix test test/cash_lens_web/live/transfer_live_test.exs test/cash_lens_web/live/automation_live/transfer_rules_test.exs` passes.
- `mix quality_check` passes with 0 errors and 0 warnings.

## Expected Results
- [ ] `/transfers` clearly separates "Pending Pairing" transfers from "Reconciled" transfers in two tabs switchable via `?tab=pending` / `?tab=history`
- [ ] `/transfers` shows a single top indicator card, "Pending Pairs", with the count of unmatched transfer transactions; no "amount moved in the month" and no "neutrality / double-taxation" card is rendered
- [ ] One-click pairing suggestion for debits and credits with the same amount and dates within 3 days, with "Confirm Pair" and "Confirm All" actions that set the `transfer_key`
- [ ] Manual link modal shows candidates with the computed amount difference and day difference
- [ ] The page header of `/transfers` (title row, inside `TransferLive.Index`, not the global layout) contains a single navigation link labelled "Regras de Transferência" pointing to `/admin/transfer_rules`, and no other action button
- [ ] The "Reapply Automatic Rules" action is no longer present on `/transfers` and is available on `/admin/transfer_rules`, where triggering it runs `Transactions.reapply_transfer_rules/0` and shows a result flash
- [ ] `mix quality_check` passes with 0 errors and 0 warnings

## Out of Scope
- Reimbursement or statement reconciliation.
- Changes to statement deduplication rules.
