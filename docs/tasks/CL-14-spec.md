# CL-14 — Redesign the credit-card statement hub (/statements) around the statement lifecycle and payment reconciliation

## Scope
Redesign `CashLensWeb.CreditCardStatementLive.Index` (route `/statements`) around the statement lifecycle: month commitment metrics at the top, statements grouped per credit card with lifecycle badges (Open / Closed / Paid / Absorbed), a one-click reconcile block when a matching bank debit is detected, manual linking when it is not, and a per-competência history whose rows open a detail view listing the cycle's transactions and installments.

Covered:
- Three metric cards at the top of the page.
- Per-card grouping with lifecycle **badges** (not tabs).
- One-click reconcile block for closed statements with a suggested bank debit.
- Manual payment linking when no suggestion exists.
- Per-competência statement history per card, opening the existing detail view.
- Absorbed statements (`absorbed_by_statement_id`) shown as absorbed and excluded from totals.
- Tests in `test/cash_lens_web/live/credit_card_statement_live_test.exs`.

Not covered:
- Changes to competência accounting in `CashLens.CreditCards.Statement` or to `absorb_pending/1`.
- File import (owned by `/imports`).
- Database schema changes or migrations.
- Manual entry of ad-hoc purchases (owned by `/transactions`).
- **No new route.** The detail view keeps the existing `?id=` query-param patch on the single `live "/statements"` route declared in `router.ex:46`; `router.ex` is therefore **not** in Files Touched.

## Approach

### 1. Behavior

**Lifecycle status.** A presentation-level status is derived per statement, on top of the existing `statement_status/2`:
- `:absorbed` — `absorbed_by_statement_id` is set (wins over everything else).
- `:paid` — a `payment_transaction_id` is set. When the existing `statement_status/2` returns `:divergent`, it is still shown as Paid but carries a divergence marker.
- `:closed` — no payment linked and `total_a_pagar` is present (cycle consolidated by an imported statement).
- `:open` — no payment linked and `total_a_pagar` is `nil` (cycle still accumulating; the displayed amount is the partial sum of its transactions).

Each status renders as a badge on the card's statement row. No tab UI is introduced.

**Top metrics**, computed over non-absorbed statements only:
- *Total due this month* — sum of `total_a_pagar` of `:closed` statements whose `due_date` falls in the current month.
- *Closed statements awaiting payment* — count of `:closed` statements.
- *Next due date* — the `:closed` statement with the earliest `due_date` on or after today: card name, date, and remaining days.

**Grouping and history.** Statements are grouped by credit-card account. Each card block shows its most recent cycle expanded, plus a collapsible history listing the card's earlier competências (one row per competência with due date, amount and lifecycle badge). Clicking any row (current cycle or history) patches to `~p"/statements?id=#{statement_id}"`, which the existing `handle_params(%{"id" => id})` already handles, and the detail view lists the cycle's transactions. Installment purchases are identified in that list by `installment_number`/`installment_group.installments` (e.g. `3/10`), which requires preloading `:installment_group` in `CreditCards.statement_transactions/1`.

**Reconciliation.** The suggestion is produced by reusing the existing `CashLens.CreditCards.suggest_payment/1` — no new matching logic. Its real behaviour must be reflected in the copy: it filters candidate transactions by the `cartao-de-credito` category, an account other than the statement's, and a `nil` `parent_transaction_id`, then ranks them by nearest match — smallest `|amount - total_a_pagar|`, tie-broken by smallest `|date - due_date|` — and returns the top one. It is a nearest match, not an equality match, so the reconcile block must show the candidate's description, date, account and amount for the user to confirm before clicking.
- `suggest_payment/1` is currently only called for statements whose internal status is `:open`; it must now be called for statements whose lifecycle status is `:closed` (the ones awaiting payment).
- The reconcile button fires the existing `handle_event("link", %{"payment-id" => id})`, which calls `CreditCards.link_payment/2` — setting `payment_transaction_id` and re-parenting the cycle's transactions under the payment — after which the statement re-renders with the Paid badge.

**No-match path.** When `suggest_payment/1` returns `nil` for a closed statement, **no reconcile block is rendered**; the statement keeps its Closed badge. In its place the detail view renders a manual-link affordance: a picker listing the ranked candidate transactions (description, date, account, amount) with a link action per row that fires the same existing `handle_event("link", %{"payment-id" => id})`. To feed the picker, `suggest_payment/1` is refactored to delegate to a new `CreditCards.payment_candidates/1` that returns the full ranked list, with `suggest_payment/1` returning `List.first/1` of it — its existing return value and behaviour are unchanged. When the candidate list is empty, an explicit empty state is shown. Paid statements keep the existing "unlink" action backed by `unlink_payment/1`.

**Absorbed statements** render with an absorbed badge and a link to the absorbing statement; they are excluded from all three top metrics so their amounts are never counted twice.

### 2. Files Touched
- `lib/cash_lens_web/live/credit_card_statement_live/index.ex` — new render structure (metric cards, per-card grouping with lifecycle badges, per-competência history, reconcile block, manual-link picker, detail view); assigns for metrics and grouping; suggestion now loaded for closed statements.
- `lib/cash_lens/credit_cards.ex` — `lifecycle_status/1` (or equivalent) mapping to `:open | :closed | :paid | :absorbed`; per-card grouping and top-metric helpers excluding absorbed statements; `payment_candidates/1` extracted from `suggest_payment/1`; `:installment_group` preloaded in `statement_transactions/1`.
- `test/cash_lens_web/live/credit_card_statement_live_test.exs` — tests listed below.
- `docs/tasks/CL-14-mock.html` — reference mockup (not shipped code).

Not touched: `lib/cash_lens_web/router.ex` (no new route).

### 3. Test Criteria
`test/cash_lens_web/live/credit_card_statement_live_test.exs` asserts:
- The three metric cards render with the expected values, and an absorbed statement's amount is not included in any of them.
- A card block renders Open, Closed and Paid badges for statements in the corresponding states, grouped under their account.
- A closed statement with a matching bank debit renders the reconcile block; clicking it triggers `link`, and afterwards the statement renders with the Paid badge, `payment_transaction_id` is set, and the cycle's transactions have `parent_transaction_id` pointing at the payment.
- A closed statement with no candidate debit renders **no** reconcile block, still renders the Closed badge, and renders the manual-link affordance; linking manually through it produces the same Paid result.
- The per-competência history lists a card's earlier statements, and patching to `?id=` for one of them renders its transactions, including an installment transaction shown with its `n/total` marker.
- `mix test test/cash_lens_web/live/credit_card_statement_live_test.exs` passes.
- `mix quality_check` passes with 0 errors and 0 warnings.

## Expected Results
- [ ] Top cards render Total Due This Month, Closed Statements Awaiting Payment, and Next Due Date (card, date and days remaining)
- [ ] Statements are grouped visually per credit card, with lifecycle status badges: Open (current cycle), Closed (consolidated amount) and Paid
- [ ] A closed statement with a matching bank debit shows a one-click reconcile block that, on click, sets the statement's `payment_transaction_id` and re-parents the cycle's transactions under that payment, flipping the status to Paid
- [ ] When no matching bank debit exists, no reconcile block is rendered and the statement remains Closed, with manual linking still available
- [ ] Statement history per competencia allows opening a detail view listing the transactions and installments included in the cycle
- [ ] Statements absorbed by re-import (`absorbed_by_statement_id`) are shown as absorbed and their amounts are not counted twice in the totals
- [ ] `mix test test/cash_lens_web/live/credit_card_statement_live_test.exs` passes
- [ ] `mix quality_check` passes with 0 errors and 0 warnings

## Out of Scope
- New routes; the detail view stays on `/statements?id=`.
- Database schema changes or migrations.
- Manual entry of ad-hoc purchases (done in `/transactions`).
