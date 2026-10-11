# CL-38 — Where the dashboard's queries come from

Base commit: `687cbc0`. Measured 2026-10-11.

This document does two separate jobs and keeps the two sets of numbers apart
throughout:

- it explains the **development database's** `GET /` cost, which is the baseline
  the follow-up tasks are measured against;
- it derives the **fixture set's** cost, which is the smaller number
  `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` asserts.

Every table below says which of the two it is. They are not interchangeable:
the real database has 4 cards and 10 open accounts, the fixture set has 2 and 4.

## How these numbers were taken

`./run` was live on the host for the whole of this task — it serves the app on
`localhost:4444` and holds the `cash_lens_pgdata` volume on port 5432 — so the
compose stack was deliberately **not** started (see the two-postmasters warning
in `AGENTS.md`).

Three measurements, three methods:

1. **Real-data query counts and attribution.** A throwaway script (not
   committed, per the spec) run as

   ```
   DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=dev \
     mix run --no-start /tmp/measure.exs
   ```

   `--no-start` keeps a second endpoint off port 4444; the script starts
   `:telemetry`, `:postgrex`, `:ecto_sql` and then `CashLens.Repo` by hand with
   `pool_size: 2`. It attaches a handler to `[:cash_lens, :repo, :query]` that
   filters on `self()` and tallies `metadata.source`, exactly as
   `CashLens.QueryCounter` does, and replays what
   `CashLensWeb.PageController.home/2` calls, in order:
   `Forecast.project(365)`, `Accounts.list_accounts/0`,
   `Accounting.list_latest_balances/0`,
   `Accounting.get_historical_balances(limit: 24)`,
   `Transactions.get_historical_summary(limit: 24)`,
   `Transactions.get_monthly_summary/0`, `Transactions.spend_rate/3`,
   `CreditCards.closed_without_statement/0`, `Forecast.upcoming_bills/1`,
   `BankruptcyCard.assigns_from/2`. The template render is left out because it
   issues no queries — every assign is already materialised before `render/3`.

   Attribution to the emitting function comes from the same handler reading
   `metadata.stacktrace` (dev config sets `stacktrace: true`) and taking the
   first `CashLens.*` frame that is not `CashLens.Repo`.

2. **Wall clock of `GET /`.** Against the live dev app, over real HTTP, so the
   figure includes the render, the layout and Bandit:

   ```
   for i in $(seq 7); do curl -s -o /dev/null -w '%{time_total}\n' http://localhost:4444/; done
   ```

3. **Fixture-set counts.** The committed test itself, via
   `CashLens.QueryCounter`:

   ```
   DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=test \
     mix test test/cash_lens_web/controllers/dashboard_query_budget_test.exs
   ```

All timings are the median of 7 runs unless stated otherwise, taken after one
discarded warm-up run.

### The dataset the real figures come from

| | |
|---|---|
| accounts | 11 (10 open) |
| open credit cards with a full cycle | 4 — Amazon (`due_day` 10), Amex (16), Cartão de Crédito (17), Ourocard (16) |
| transactions | 5301 |
| credit-card statements | 47 (8 unpaid, 0 with a null `total_a_pagar`) |
| installment groups | 115 |
| balances | 156 |
| recurring items | 23 |

## Query groups on the development database

492 queries per `GET /`, every one attributed:

| Count | Source table | Emitted by |
|---:|---|---|
| 320 | `installment_groups` | `Installments.account_installment_groups/2` (`installments.ex:49`), reached from `Forecast.card_occurrences/2` → `card_occurrence_for_date/2` → `estimate_for_month/2` → `variable_part/1` → `Installments.account_installment_total/2` |
| 1 | `installment_groups` | `Forecast.commitment_occurrences/2` → `Installments.list_off_card_groups/0` |
| 48 | `credit_card_statements` | `Forecast.card_occurrence_for_date/2` → `statement_for_month/2` (`forecast.ex:951`) |
| 46 | `credit_card_statements` | `Forecast.estimate_for_month/2`'s recent-bill sample (`forecast.ex:1038`) |
| 1 | `credit_card_statements` | `CreditCards.closed_without_statement/2` (`credit_cards.ex:531`) |
| 30 | `balances` | `Accounting.ensure_active_balances_healed/0`'s per-account `exists?` (`accounting.ex:454`) — 3 call sites × 10 open accounts |
| 1 | `balances` | `Accounting.list_latest_balances/0`, via `Forecast.current_balance/0` |
| 1 | `balances` | `Accounting.list_latest_balances/0`, from the controller |
| 1 | `balances` | `Accounting.get_historical_balances/1` |
| 12 | `transactions` | `Forecast.monthly_volatility/0` → `monthly_net/1`, one per month of the 12-month window |
| 2 | `transactions` | `Transactions.get_historical_summary/1` — once from the controller, once inside `Transactions.spend_rate/4` |
| 2 | `transactions` | `Transactions.get_monthly_summary/2`: `get_latest_transaction_date/0` plus the aggregate |
| 1 | `transactions` | `Forecast.overdue_occurrences/1` → `get_latest_transaction_date/0` |
| 1 | `transactions` | `Forecast.settled_categories/2` |
| 1 | `transactions` | `Forecast.variable_spending_total/2` |
| 6 | `categories` | `Transactions.excluded_cash_summary_category_ids/0` → `Categories.get_category_by_slug/1`, 2 slugs × 3 summary reads |
| 6 | `categories` | the same function's `Categories.get_category_ids_with_children/1` recursive CTE, 2 subtrees × 3 summary reads |
| 1 | `categories` | `Forecast.variable_spending_total/2`'s fixed-category id list |
| 3 | `accounts` | `Accounting.ensure_active_balances_healed/0`'s active-account list, once per call site |
| 2 | `accounts` | `Forecast.current_balance/0` — `list_latest_balances/0` plus `Accounts.list_accounts/0` |
| 1 | `accounts` | `Forecast.card_accounts/0` → `Accounts.list_accounts/0` |
| 1 | `accounts` | `Accounts.list_accounts/0`, from the controller |
| 1 | `accounts` | `Accounting.list_latest_balances/0`, from the controller |
| 1 | `accounts` | `CreditCards.closed_without_statement/2` |
| 1 | `recurring_items` | `Forecast.project/2` → `list_recurring_items/0` |
| 1 | `recurring_items` | `Forecast.overdue_occurrences/2` → `list_recurring_items/0` |

Totals: `installment_groups` 321, `credit_card_statements` 95, `balances` 33,
`transactions` 19, `categories` 13, `accounts` 9, `recurring_items` 2 — **492**.

`Forecast.upcoming_bills/1`, `ruler_occurrences/2`, `occurrences_within/2`,
`trough/2`, `final_balance/1` and `BankruptcyCard.assigns_from/2`'s own work
issue no queries: they are slices of a projection already in memory. The
template issues none either.

## The scaling law of the two large groups

For one card, inside a 365-day horizon:

```
statements_q(card) = D + E
   groups_q(card)  = E * (S + 2)        when S >= 1
   groups_q(card)  = 0                  when S == 0
```

where

- **`D`** = due-dates inside `[today, today + 365]` = **12**, or **13** when
  `due_day == today.day` (then the first date is today and the twelfth-next
  lands exactly on the horizon's last day, so both are inside it);
- **`E`** = `D` minus the due-months that already have a statement row — the
  months that fall through to `estimate_for_month/2`. A month with a statement
  costs one query and stops, whether the statement is paid or not;
- **`S`** = `min(@estimate_sample = 6, statements with due_date >= today - 180)`
  — the sample `estimate_for_month/2` averages;
- **`+2`** = `Installments.account_installment_total/2` for the month being
  estimated, plus the `account_installment_groups/2` call that builds the
  parcel disclosure. The `S` term is the same function once per sampled
  statement, through `variable_part/1`.

Measured per card on the development database:

| Card | `due_day` | `D` | months with a statement | `E` | `S` | statements | groups |
|---|---:|---:|---:|---:|---:|---:|---:|
| Amazon | 10 | 12 | 0 | 12 | 2 | 24 | 48 |
| Amex | 16 | 12 | 1 | 11 | 6 | 23 | 88 |
| Cartão de Crédito | 17 | 12 | 0 | 12 | 6 | 24 | 96 |
| Ourocard | 16 | 12 | 1 | 11 | 6 | 23 | 88 |
| **total** | | | | | | **94** | **320** |

Adding the one query each that lives outside `card_occurrences/2` —
`CreditCards.closed_without_statement/2` for the statements and
`Installments.list_off_card_groups/0` for the groups — gives **95** and
**321**.

**Finding 1 — the reported 321 and 95 reproduce exactly.** Not approximately:
to the unit, from the per-card formula, on a dataset whose card count is 4.
Note that Amazon's `S` is 2, not 6: it has only two statements inside the
180-day window, which is why 4 cards and ~46 estimating months come to 320
rather than 368.

## Cost per dashboard section

Development database. Queries from a single run (the count is deterministic —
five runs gave 492 every time); milliseconds are the median of 5.

| Section | Queries of its own | ms | Notes |
|---|---:|---:|---|
| KPIs (Saldo Atual / Receitas / Despesas / Balanço / ritmo) | 30 | 15.0 | `list_latest_balances/0` 13 q / 4.5 ms, `get_monthly_summary/0` 6 q / 3.2 ms, `spend_rate/3` 11 q / 7.3 ms |
| Upcoming bills ("Próximas Contas") | 0 | <0.1 | a 30-day slice of the shared projection; it buys no query of its own |
| Bankruptcy card ("Projeção de Falência") | 12 | 7.3 | all of it `monthly_volatility/0`; `trough/2` and `final_balance/1` are pure |
| Chart ("Evolução Financeira Consolidada") | 17 | 9.1 | `get_historical_balances(24)` 12 q / 4.0 ms + `get_historical_summary(24)` 5 q / 5.1 ms |
| History table (12 months) | 0 | 0.0 | the same two reads as the chart, rendered twice |
| Accounts list ("Minhas Contas") | 1 | 1.3 | `list_accounts/0`; the balances it shows come from the KPIs' read |
| *(closed-statement notice)* | 2 | 0.7 | `closed_without_statement/0` |
| **Shared: `Forecast.project(365)`** | **436** | **304** | charged once, read by the bill list *and* the bankruptcy card |

Inside the shared projection:

| Part | Queries | ms |
|---|---:|---:|
| `card_occurrences/2` | 415 | 342 |
| `current_balance/0` | 14 | 5.8† |
| `overdue_occurrences/0` | 3 | 1.4 |
| `variable_baseline_rate/0` | 2 | 1.5 |
| `commitment_occurrences/2` | 1 | 1.0 |
| `list_recurring_items/0` | 1 | <1 |

† `current_balance/0` was not timed on its own; 5.8 ms is the sum of its two
reads, `list_latest_balances/0` (4.5 ms) and `list_accounts/0` (1.3 ms), both
timed above. The same is true of the two sections that share a pair of reads:
the KPIs' 15.0 ms and the chart's 9.1 ms are the sums of their parts, each part
a median of 5.

`card_occurrences/2` is 84% of the projection's queries and essentially all of
its time. The sum of the individual query durations inside `project/365` is
300 ms against a 304 ms wall clock: the function is database round trips and
almost nothing else.

## The real-data baseline, two columns

| Metric | Previously reported (**unverified**) | Re-measured 2026-10-11 |
|---|---|---|
| Queries per `GET /` | 466 | **492** |
| of which `installment_groups` | 321 | **321** |
| of which `credit_card_statements` | 95 | **95** |
| `Forecast.project(365)` | ~433 ms | **304 ms** (median of 7; 264–329) |
| `GET /` wall clock | ~350 ms | **424 ms** over HTTP (median of 7; 408–493) |
| `GET /` data assembly, in process | — | 338 ms (median of 7; 291–377) |

The re-measured column is the baseline the follow-ups are measured against. The
previously reported column is history and is unverified — the development
database has moved since it was taken.

**Finding 2 — the total is 26 queries higher than reported, and none of the
difference is in the two large groups.** `installment_groups` and
`credit_card_statements` match to the unit, so the gap sits entirely in the
groups that scale with the number of **open accounts** rather than with the
horizon: `balances` is 33, of which 30 are
`ensure_active_balances_healed/0`'s per-account `exists?` (3 call sites × 10
open accounts), and `accounts` is 9. Three commits since the figure was taken
touched the account set, `936884a feat(accounts): give the accounts an order of
their own, and an investment flag` among them; at 7 open accounts the healing
probe would have cost 21 instead of 30. The earlier dataset cannot be
reconstructed, so the 26 cannot be attributed query by query — that it is
*outside* the card groups is as far as the measurement supports.

**Finding 3 — `project(365)` measures 304 ms against a reported ~433 ms, while
issuing the same 436 queries.** The work is not different: the per-card formula
reproduces the reported group sizes exactly, and the sum of query durations
(300 ms) accounts for the whole wall clock. The likeliest explanation is the
measurement environment — a colder connection pool, a busier machine, or a
first (unwarmed) run, since an unwarmed run here came in at 386 ms. Recorded as
a gap, not resolved.

**Finding 4 — over real HTTP the page is slower than reported, not faster.**
424 ms median against ~350 ms, and 86 ms above the in-process assembly (338 ms).
The difference between the two re-measured figures is the template render, the
layout and Bandit, none of which touch the database.

## Fixture-set counts — what the test asserts

These are the committed test's numbers, on 2 cards and 4 open accounts. They
are **not** the development database's.

| Source table | Measured | Delta | Ceiling |
|---|---:|---:|---:|
| `installment_groups` | 177 | +16 | 193 |
| `credit_card_statements` | 47 | +4 | 51 |
| `transactions` | 19 | 0 | 19 |
| `balances` | 15 | 0 | 15 |
| `categories` | 13 | 0 | 13 |
| `accounts` | 9 | 0 | 9 |
| `recurring_items` | 2 | 0 | 2 |
| **total** | **282** | **+20** | **302** |

The same formula reproduces them: 2 cards, each with `D = 12`, one due-month
carrying a statement so `E = 11`, and `S = 6`. Statements
`2 × (12 + 11) = 46`, plus `closed_without_statement/0` → **47**. Groups
`2 × 11 × 8 = 176`, plus `list_off_card_groups/0` → **177**.

### Why the delta is what it is

`ceiling = measured_fixture_count + delta`, and the only admissible delta is
one extra due-month per card:

- `E` is 11 as measured, and its maximum is **12**: when `due_day > today.day`,
  `D = 12` and the current month is in the horizon with a statement in it, so
  `E = 11`; when `due_day == today.day`, `D = 13` with the same statement, so
  `E = 12`; when `due_day < today.day` the current month is not in the horizon
  at all, so `E = D = 12`. One more, never two.
- One extra due-month costs **2** `credit_card_statements` queries
  (`statement_for_month/2` + the estimate sample) and **8** `installment_groups`
  queries (`S = 6`, plus the month's own total, plus the disclosure).
- So `delta = cards × 1 × 2 = 4` for `credit_card_statements`,
  `cards × 1 × 8 = 16` for `installment_groups`, and `4 + 16 = 20` for the
  total.
- `delta = 0` for every other table. None of them is driven by the due-month
  calendar: `transactions` would only grow through
  `CreditCards.statement_transactions/1`, which runs on a bill with a null
  `total_a_pagar` — the fixture set gives every statement one, and an extra
  due-month is always an *estimate*, which reads no transaction. `balances`,
  `accounts` and `categories` scale with the number of open accounts and the
  number of summary reads; `recurring_items` is a flat 2.

No rounding, no headroom.

**Finding 5 — the `>= 1` lower bounds cannot fail against today's controller.**
Every one of the seven tables is read at least once unconditionally — even with
no cards at all, `closed_without_statement/0` still queries
`credit_card_statements` and `list_off_card_groups/0` still queries
`installment_groups`. Deleting the fixture rows that feed a table therefore
does *not* make its lower bound fail, because the tally counts queries issued,
not rows returned (verified: deleting every `recurring_items` row leaves the
count at 2). What the lower bounds do catch is the failure mode that would make
every ceiling vacuous at once — a change in Ecto's `:source` metadata, or in
`QueryCounter`'s attribution, that leaves `by_table` empty while `total` keeps
rising. That is worth asserting, and it is asserted. They would also catch a
future controller that stopped reading one of the seven tables on the common
path. They are not a substitute for the fixture set's richness, and this
document is the record that they are not.

## Inherent cost versus defect

### Inherent — about 33 queries on real data

One read per thing the page shows, none of them repeated per month or per
account: `Accounts.list_accounts/0` (1), `list_latest_balances/0` (1),
`get_historical_balances/1` (1), `get_historical_summary/1` (1 per caller),
`get_monthly_summary/0` (2), `closed_without_statement/0` (2),
`variable_spending_total/2` (2), `overdue_occurrences/1` (2 ledger reads),
`settled_categories/2` (1), `list_recurring_items/0` (1),
`list_off_card_groups/0` (1), plus one statement read and one estimate sample
**per card** (4 + 4). Nothing here is reducible without changing what the
dashboard says.

### Defects

| # | Group | Now (real) | Should be | Why it is a defect |
|---|---|---:|---:|---|
| D1 | `installment_groups` | 320 | 4 | `Installments.account_installment_groups/2` loads *every* group touching the account and filters parcels in Elixir, and is called once per sampled statement per estimated month. The set of groups per account does not change between the months being estimated, and the parcel filter is pure — one read per card would serve all of them. |
| D2 | `credit_card_statements` | 94 | 8 | `statement_for_month/2` asks for one month at a time (48), and `estimate_for_month/2` re-reads the *same* six-statement sample once per due-month (46). Both are one query per card: the horizon's statements in one read, the sample in another. |
| D3 | `balances` + `accounts` | 33 + 9 | 6 + 4 | `ensure_active_balances_healed/0` issues one `exists?` per open account (10) and runs on all three of its call sites per request (30). One grouped query answers it for every account, and once per request is enough. `list_latest_balances/0` and `list_accounts/0` are each read more than once per render. |
| D4 | `transactions` | 19 | 8 | `monthly_volatility/0` runs one query per month of its 12-month window. A single `group_by` over the window returns the same 12 nets. |
| D5 | `categories` | 13 | 5 | `excluded_cash_summary_category_ids/0` recomputes two slug lookups and two recursive CTEs on each of the three summary reads. The answer is identical within a request. |

### Judged not worth fixing

- **`overdue_occurrences/1`'s two ledger reads** (`get_latest_transaction_date/0`
  and `settled_categories/2`) and **the variable baseline's two**. One query
  each per request; folding them into neighbours would couple unrelated
  questions to save two round trips.
- **`get_historical_summary/1` read twice** (once by the controller, once inside
  `spend_rate/4`). It is 1 query, and passing the rows down would put a
  reporting detail into `spend_rate/4`'s signature for no measurable gain.
  D3 already covers the duplicates that are worth removing.
- **`closed_without_statement/0`'s two queries.** Two reads for a notice the
  page cannot render without them.

## Follow-up tasks and the ceilings they must reach

The ceilings below are the **fixture set's**, because that is what the test
asserts. Each one is `new_measured + new_delta`, with the new delta falling to
zero wherever the group stops scaling with the due-month calendar.

| Task | Defects | Ceilings it must bring the test down to |
|---|---|---|
| CL-39 | D1, D2 | `@installment_groups_ceiling` 193 → **3**, `@credit_card_statements_ceiling` 51 → **5**, `@total_ceiling` 302 → **66**, and both deltas to **0** |
| CL-40 | D3 | `@balances_ceiling` 15 → **6**, `@accounts_ceiling` 9 → **5** |
| CL-41 | D4 | `@transactions_ceiling` 19 → **8** |
| CL-42 | D5 | `@categories_ceiling` 13 → **5** |

CL-39's arithmetic: `282 − (177 − 3) − (47 − 5) = 66`, and after it neither
group is driven by due-months any more, so the 20-query calendar delta goes to
zero. With all four landed the fixture set's total reaches
`66 − 9 − 4 − 11 − 8 = 34`, and the development database's `GET /` goes from
492 to roughly 55.

CL-39 is the only one that matters to the page's wall clock: it is the 342 ms of
`card_occurrences/2`. The other three are 27 queries and about 20 ms between
them, and are worth doing for the same reason the budget exists — so that the
cheap path stays cheap.

## The operational consequence

`taildash` probes `GET /` with a **0.3 s timeout**. The page answers in 424 ms
(median of 7; the fastest of the seven was 408 ms, so not one run came in under
the timeout). Every probe therefore times out, and `taildash` lists cash_lens as
**non-web** — not because the app is down, but because `/` is slower than the
probe is willing to wait. The listing will keep saying that until `/` answers
inside 0.3 s, which means CL-39: taking `card_occurrences/2`'s 342 ms out of the
request is the only one of the four follow-ups large enough to cross that line.

## What this task could not do

`mix precommit` does not pass, and it did not pass before this task either. At
`687cbc0`, with every file added here removed from the tree, it fails three
times over: `mix compile --warnings-as-errors` on
`lib/cash_lens/imports.ex:136` (`put_import_root/1`'s clauses are not grouped),
`mix credo --strict` with exit 30 on about 23 pre-existing findings across
`lib/cash_lens/accounting.ex`, `credit_cards.ex`, `forecast.ex`, `parsers/*`,
`lib/cash_lens_web/controllers/page_controller.ex` and
`test/cash_lens/accounting_test.exs`, and two calendar-dependent test failures
(`test/cash_lens/forecast_test.exs:2283`,
`test/cash_lens_web/controllers/page_controller_test.exs:285` — both pin a
card's `due_day` to 10 and then assert on a statement due today + 4, which stops
holding after the 10th of a month).

Fixing any of it means editing `lib/`, which this task is explicitly barred
from. It is **CL-43** instead. Everything this task does add is clean on its own
terms: formatted, Credo-silent, and green —
`mix test test/cash_lens_web/controllers/dashboard_query_budget_test.exs
test/cash_lens/query_counter_test.exs` is 6 tests, 0 failures.
