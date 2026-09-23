# CL-33 — Introduce a cash-accounts scope for the global screens

## Scope

Introduce one named, documented query scope meaning "cash accounts only"
(accounts with `is_credit_card == false`) and rewire the global
listing/reporting queries that **already** filter by hand to use it.

This task covers only the extraction and the rewiring. It does **not** change
which rows any screen shows: the dashboard, transfers screens and forecast
suggestion helper already filter today, and they must keep returning exactly
what they return at base commit `2aa964c`.

It explicitly does **not** add the filter to `/transactions` (CL-34),
`/balances` (CL-35) or `/months` (CL-31), which do not filter today and are
changed by their own tasks. It does not touch the Installments context, the
CreditCards context, or the credit-card side of Forecast.

The central hazard: Forecast reaches installment data through
`CashLens.Installments` (`account_installment_groups/2`,
`account_installment_total/2`, `parcel_value/1`, `parcel_position/2`,
`list_off_card_groups/0`), and **every one of the 231 installment-linked
transactions in the production database sits on a credit-card account**. A
scope applied to a helper Installments also uses would empty the forecast
silently. The guard tests below exist for that.

## Approach

### Behavior

- The module is `CashLens.Accounts.Scopes`, in `lib/cash_lens/accounts/scopes.ex`
  (no other module in `lib/` contains the token `Scope` today, so the name is
  unambiguous for grep). Consumers `alias CashLens.Accounts.Scopes` and call it
  as `Scopes.<fun>(...)`; the greps in the expected results therefore use the
  fully-qualified name `CashLens.Accounts.Scopes` for absence checks and the
  string `Scopes.` (short name plus dot, which matches both the aliased and the
  fully-qualified call form, and never the bare `alias` line) for the
  presence checks inside functions.
- It takes an Ecto query whose root schema
  has an `:account` association (in practice `Transaction`) and restricts it to
  non-credit-card accounts. It supports two shapes: joining the account itself
  (default), and applying the predicate to an account binding the caller has
  already named (needed by the two-sided transfer self-join).
- Its `@moduledoc`/`@doc` states what the scope is for (the "global" screens:
  dashboard, transfers, forecast suggestions, and later the listing screens)
  and states explicitly that `CashLens.Installments`, `CashLens.CreditCards`
  and the credit-card branches of `CashLens.Forecast` must NOT use it, naming
  the forecast-emptying failure mode as the reason.
- Every rewired call site produces the same result set as before. No new public
  context function, no signature change, no schema change, no migration.

### Files touched

- `lib/cash_lens/accounts/scopes.ex` — **new**: the `CashLens.Accounts.Scopes`
  module and its docs.
- `lib/cash_lens/transactions.ex` — replace the hand-written
  `is_credit_card`/`not acct.is_credit_card` predicates in
  `apply_summary_account_filter/2` (the "no account_id" branch of
  `get_monthly_summary/2`), `get_historical_summary/1`,
  `list_transfer_suggestions/0` (both account bindings; name them so the scope
  can be applied twice), `list_unmatched_transfers_without_suggestion/1` and
  `list_transfer_link_candidates/1` with calls to `Scopes.*` (aliased via `alias CashLens.Accounts.Scopes`
  alongside the existing alias block at lines 7-18). **Also rewrite the
  two `@doc` sentences that name the flag in prose** — line 468
  (`get_monthly_summary/2`: "Considers only bank accounts (is_credit_card:
  false) unless a specific account_id filter is passed.") and line 652
  (`get_historical_summary/1`: "Considers only bank accounts (is_credit_card:
  false).") — so they refer to the scope by name instead of to the column. After
  this task the string `is_credit_card` must not appear anywhere in
  `lib/cash_lens/transactions.ex`, in code or in prose; that is what makes the
  grep in the expected results decidable without reading the diff.
- `lib/cash_lens/forecast.ex` — `suggest_for_category/1` only: replace its
  inline `a.is_credit_card == false` with a `Scopes.*` call (same alias
  convention). Lines 298 and 364 (the
  card-bill occurrence logic) are left untouched.
- `test/cash_lens/accounts/scopes_test.exs` — **new**: unit tests for the scope.
- `test/cash_lens/installments_scope_guard_test.exs` — **new**: the guard that
  Installments still sees credit-card accounts.
- `test/cash_lens/forecast_scope_guard_test.exs` — **new**: pins the
  `:estimado` card-bill occurrence together with its installment disclosure
  (see "Test criteria" for why that branch specifically).

### Deliberate non-users of the scope

These keep their explicit `is_credit_card` predicate, and the implementer lists
them in the task report with one line each:
`Accounts.list_bank_accounts/0`, `Accounts.list_credit_card_accounts/0`
(they *define* the two sets), `Accounting.get_historical_balances/1` (zeroes
card balances with a `CASE` expression rather than dropping rows),
`Forecast` lines 298 and 364 (card-bill occurrences),
`CreditCards` / `CreditCards.Matcher` (card-only by definition),
`Installments.list_off_card_groups/0` (must keep seeing card accounts),
plus the ingestion/UI-side `is_credit_card` reads
(`Parsers.Ingestor`, `Parsers.DirectoryImporter`,
`Transactions.TransferRuleApplier`, `MonthLive.Show`, `PageController`,
`AccountLive.FormComponent`, the API account controller and the
`migrate_credit_card_transfers` mix task).

### Test criteria

- Scope unit tests: a transaction on a card account is excluded, one on a bank
  account is kept, and the `on:`/pre-named-binding form behaves identically to
  the joining form.
- Installments guard: with a group whose transactions live on a credit-card
  account, `account_installment_groups/2` returns the group,
  `account_installment_total/2` returns its non-zero parcel sum, and
  `parcel_value/1` returns the parcel value — i.e. the scope did not leak in.
- Forecast guard: the fixture must force the **`:estimado`** branch of
  `Forecast.card_occurrences/2`, because that is the only branch that calls
  `Installments.account_installment_groups/2` — the query a leaked scope would
  empty. Concretely: one open credit-card account with `closing_day`/`due_day`,
  one `Statement` whose `due_date` lies in the recent-history window (so
  `estimate_for_month/2` returns an amount) and **no** statement for the
  forecast month itself (so `card_occurrence_for_date/2` takes the `nil`
  branch), plus one named installment group whose transactions sit on that card
  account. The assertion must not be on the bill amount alone: on this branch
  `estimate_for_month/2` computes `statement_amount + recent_installments -
  future_installments`, which is unchanged when both installment totals collapse
  to zero. The test therefore asserts on the occurrence's disclosure —
  `origin == :estimado`, a non-zero `installment_total` equal to the group's
  parcel value, and an `installment_groups` entry for the named group carrying
  its exact `parcel_value` and `parcel_number`. Emptying
  `account_installment_groups/2` then necessarily fails the test. The
  `:boleto` branch (imported statement, where `installment_disclosure(nil)`
  returns `{0, []}`) and the off-card path
  (`commitment_occurrences/2` via `Installments.list_off_card_groups/0`) do not
  satisfy this criterion, because neither touches the query under guard.
- Forecast-guard falsification (implementer duty, recorded as an artefact): run
  `test/cash_lens/forecast_scope_guard_test.exs` once with
  `Installments.account_installment_groups/2` temporarily stubbed to return
  `[]`; the test must fail. Paste the failure output — including the name of the
  failed assertion — into `.meridian/reports/CL-33-in_progress-1.md` under the
  exact heading `## Forecast guard falsification run`, then revert the stub. QA
  verifies the artefact, not the stubbed run.
- Whole-suite and production-data checks as listed in Expected Results.

### Database environment (required to run any data-touching check)

The shared Postgres volume is published on `localhost:5432` **only while
`./run` is live** (it starts the `cash_lens-db-native` container with the port
published); `docker-compose.yml` deliberately never publishes it. Both
`config/dev.exs` and `config/test.exs` default to `localhost:5432`. Therefore:

- The production-data figures are read in `MIX_ENV=dev` against that database,
  with `./run` live. They were measured at base commit `2aa964c` in exactly
  that environment.
- The test suite is run **on the host** (`MIX_ENV=test mix test`), for the same
  reason: it is the only way to reach a database while `./run` holds the volume.
- The containerised suite (`./run test` / compose) must never be started while
  `./run` is live — two postmasters on one volume. Do **not** stop `./run` to
  satisfy that rule either: with `./run` stopped there is no reachable Postgres
  on the host at all and no data-touching check can be executed. Keep `./run`
  live and run everything on the host.

## Expected Results

- [ ] `CashLens.Accounts.Scopes` exists, documented, used by all six rewired
      call sites.
- [ ] Installments and Forecast outputs for credit-card data are unchanged.
- [ ] The production-data figures still hold, read in `MIX_ENV=dev` with
      `./run` live.
- [ ] Suite green apart from the two known pre-existing failures; format clean;
      no new credo findings per touched file.
- [ ] The `lib/` diff against `2aa964c` adds no file beyond the three CL-33
      paths — the pre-existing uncommitted edits to
      `lib/cash_lens/pluggy/live_preview.ex` and
      `lib/cash_lens/transactions/category_suggester.ex` are unrelated work that
      must never be staged, reverted or formatted, and every diff-shaped check
      excludes them explicitly.

(The authoritative, mechanically checkable list lives in the task's
`expected_results`.)

## Out of Scope

- `/transactions` (CL-34), `/balances` (CL-35), `/months` (CL-31).
- Any change to `Accounting.get_historical_balances/1`.
- Any UI change; no mockup is produced, because this task must be
  user-invisible.
