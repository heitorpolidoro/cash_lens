# CL-38 — Pin the dashboard query count with a test, and explain it

## Scope

The dashboard (`GET /`, `CashLensWeb.PageController.home/2`) was reported to
issue 466 database queries per load on the real dataset, among them 321 against
`installment_groups` and 95 against `credit_card_statements`. Those figures are
unverified — the development database has moved since — so this task re-measures
them as well as recording them. Nothing in the suite notices that number, and
nobody has written down where it comes from.

This task covers two deliverables and one piece of bookkeeping:

1. **A regression test** that counts the queries a `GET /` render issues against
   a fixed fixture set, in total and per source table, and fails when the count
   rises above a ceiling recorded in the test.
2. **A written breakdown** that attributes every query group to the code that
   emits it, gives each dashboard section a cost in queries and in milliseconds,
   separates inherent cost from defect, and records the real-data baseline the
   follow-ups will be measured against.
3. **Follow-up tasks on the board**, one per defect worth fixing, each carrying
   the ceiling it must bring the test down to.

It explicitly does **not** cover fixing any of it. No query is to be eliminated,
batched, cached or preloaded here; no module under `lib/cash_lens/` or
`lib/cash_lens_web/` changes behaviour. The test must be green on arrival
precisely because the ceiling is whatever today's code does — a measured
baseline, not a target. A ceiling that required a code change to pass would make
this task two tasks.

## Approach

### Behaviour

**A query counter available to tests.** A test-support module collects
`[:cash_lens, :repo, :query]` telemetry events for the duration of a block and
returns both the total and a tally keyed by source table. Three properties it
must have, each because the naive version gets it wrong:

- It counts only events emitted by the process that is collecting — the handler
  runs in the emitting process, so `self()` identifies it — otherwise a
  concurrently running async test inflates the count and the ceiling becomes
  flaky. The test module stays `async: false` regardless.
- It ignores events whose `:source` metadata is `nil`: sandbox `begin`,
  `commit`, `rollback` and `savepoint` statements are an artifact of the test
  transaction, not of the dashboard.
- It detaches its handler even when the block raises, so a failure in one test
  cannot leak counting into the next.

**A dashboard query-budget test.** One `CashLensWeb.ConnCase` test module, which
builds a fixture set rich enough that every query group the dashboard has is
actually exercised — at minimum: two open credit-card accounts with
`closing_day` and `due_day` set, two open cash accounts, one closed account, a
handful of statements on each card (some paid, some not, enough to reach the
estimate sample), installment groups both on-card and off-card, active recurring
items including one overdue and one salary, balances and transactions spread
across enough months to feed the 12-month history and the volatility window. It
then renders `GET /`, asserts `200`, and asserts the count.

Two constraints on that fixture set, both load-bearing:

- **All dates are derived from `Date.utc_today()`**, never written as literals.
  The dashboard projects 365 days forward from today and reads 12 and 24 months
  back; a fixture pinned to 2026 stops exercising those windows as the clock
  moves, and the ceiling silently stops meaning anything.
- **The assertions are upper bounds (`<=`), not equalities**, and the margin
  above the measured count is computed, not chosen. The number of card due-dates
  inside a 365-day horizon is 12 or 13 depending on where today falls relative to
  `due_day`, so an exact count is calendar-dependent by construction, and that
  calendar variance is the *only* admissible source of margin. The rule, which
  the test must follow and the breakdown must state:
  `ceiling = measured_fixture_count + delta`, where `delta` is at most one extra
  due-month's worth of queries per card for the groups driven by due-months
  inside the horizon (`credit_card_statements`, `installment_groups`, and the
  share of the total they contribute), and `delta = 0` for every table that does
  not scale with the horizon (`accounts`, `balances`, `transactions`,
  `recurring_items`, `categories`). Next to each ceiling attribute, a comment
  writes the derivation out: the measured count, the delta, and the per-card
  per-due-month factor it came from. A margin that cannot be derived that way is
  not a margin; no rounding up, no headroom "to be safe".

**Per-table assertions.** The total is asserted, and so is each table that
contributes a material share — at least `installment_groups`,
`credit_card_statements`, `transactions`, `balances`, `accounts`,
`recurring_items`, `categories`. Each is its own assertion so that a regression
report names the table that grew rather than only the total. Tables outside that
list are covered by the total.

Each of those seven tables is asserted **two-sided**: `>= 1` as well as
`<= ceiling`. The tally is keyed by source table, so a table the fixture set
never reaches is simply absent from it, and a one-sided `0 <= ceiling` passes
while asserting nothing — the fixture gap that caused it goes green instead of
red. The lower bound is what makes "the fixture set exercises every query group"
a checked property rather than a prose intention; it is `>= 1`, not a second
measured number, because only the upper bound is a regression budget.

**The breakdown document.** `docs/tasks/CL-38-measurements.md`, following the
shape of `docs/tasks/CL-30-measurements.md`. It must contain:

- A table of query groups: count, source table, and the module and function that
  emits it. The call paths that have to appear by name, because they are where
  the bulk lives: `Forecast.project/2` →`card_occurrences/2` →
  `card_occurrence_for_date/2`, whose `statement_for_month/2` and
  `estimate_for_month/2` each run one query per card per due-month in the
  horizon; `estimate_for_month/2` → `variable_part/1` →
  `Installments.account_installment_total/2`, which runs one query per sampled
  statement per card per month and whose
  `Installments.account_installment_groups/2` loads every group touching the
  account and filters parcels in Elixir; `Forecast.monthly_volatility/0` →
  `monthly_net/1`, one query per month of the window; plus the dashboard's own
  `Accounting.list_latest_balances/0`, `Transactions.get_monthly_summary/0`,
  `Transactions.get_historical_summary/1`,
  `Accounting.get_historical_balances/1`,
  `CreditCards.closed_without_statement/0` and `Forecast.upcoming_bills/2`.
- The scaling law for the two large groups, written as a formula in cards,
  due-months inside the horizon, and the estimate sample size, with the observed
  321 and 95 shown to follow from it on the real dataset's card count. If the
  arithmetic does not reproduce the observed numbers, the gap is itself a finding
  and is written down as one.
- A measured cost per dashboard section — KPIs, upcoming bills, bankruptcy card,
  chart, history table, accounts list — in queries and in milliseconds.
- The real-data baseline, in two columns side by side: the **previously
  reported** figures — 466 queries per load, `Forecast.project(365)` at ~433 ms,
  `GET /` at ~350 ms wall clock — restated as such, and the **re-measured**
  figures this task obtains from the development database by the method below.
  The re-measured column is the baseline the follow-ups are measured against;
  the previously reported column is history, and is labelled as unverified.
  Where the two disagree, both are recorded and the gap is itself a finding,
  written down as one with whatever explanation the measurement supports (a
  changed dataset, a different card count, a mis-report) — exactly as for the
  321/95 arithmetic. The spec does not require the re-measurement to land on
  466, 433 or 350, and a document that reports different numbers with the gap
  explained satisfies this requirement; a document that reports only one column
  does not.
- An explicit split of inherent cost from defect, naming for each defect the
  ceiling a fix should bring the test down to.
- The operational consequence, stated plainly: `taildash` probes `GET /` with a
  0.3 s timeout, so it reports cash_lens as non-web until `/` answers inside it.

Measurements on real data are taken against the development database. The
harness may be an ad-hoc `mix run` script and is **not** committed; what is
committed is the method, written in the document in enough detail to re-run it.
The test's own fixture counts are a separate, smaller number, and the document
must not confuse the two — it records both and labels which is which.

**Follow-up tasks.** Each defect the breakdown judges worth fixing becomes its
own `backlog` task, created through the Meridian API (`POST
/api/projects/tasks`), whose `justification` points at this document and whose
`expected_results` name the query ceiling it must bring the test down to. A
defect judged not worth fixing stays in the document with the reason, and gets no
task.

### Files touched

- `test/support/query_counter.ex` — new; telemetry-based query counting helper.
- `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` — new; the
  fixture set, the `GET /` render, the total and per-table ceilings.
- `docs/tasks/CL-38-measurements.md` — new; the breakdown.
- `test/support/fixtures/*.ex` — only if the fixture set needs an attribute the
  existing factories cannot express; extend, never repurpose.
- No file under `lib/` changes.

### Test criteria

- `mix test test/cash_lens_web/controllers/dashboard_query_budget_test.exs`
  passes on arrival, with no change under `lib/`.
- Raising any ceiling attribute is the only edit that can make a genuine
  regression pass — verified by temporarily lowering a ceiling by one and
  observing the failure name the table.
- The failure message of a per-table assertion identifies the table.
- Every ceiling equals the measured fixture count plus a delta derived only from
  the due-month calendar variance, zero where the table does not scale with the
  horizon, and the derivation is readable in a comment beside the attribute.
- Deleting the fixture rows that feed any one of the seven tables makes that
  table's `>= 1` assertion fail, rather than passing on an absent key.
- `mix precommit` passes: the new test is `async: false`, formatted, and
  Credo-clean.

## Expected Results

- [ ] `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` renders
      `GET /` against a fixed fixture set, counts the queries, and fails when the
      total exceeds the ceiling recorded in the test; it passes with no change
      under `lib/`.
- [ ] The same test asserts, for each of `installment_groups`,
      `credit_card_statements`, `transactions`, `balances`, `accounts`,
      `recurring_items` and `categories`, both `>= 1` and `<= ceiling`, so a
      failure names the table and an unexercised group cannot pass vacuously.
- [ ] Every ceiling attribute carries a comment deriving it as
      `measured_count + delta`, where `delta` is zero for the tables that do not
      scale with the forecast horizon.
- [ ] `test/support/query_counter.ex` tallies `[:cash_lens, :repo, :query]`
      events by source table, counting only the collecting process and skipping
      events with a `nil` source.
- [ ] `docs/tasks/CL-38-measurements.md` attributes every query group to the
      function that emits it, gives the scaling formula for the
      `installment_groups` and `credit_card_statements` groups and reconciles it
      with the reported 321 and 95 (recording any gap as a finding), and states a
      queries-and-milliseconds cost for each of the six dashboard sections.
- [ ] The same document records the previously reported baseline (466 queries,
      `Forecast.project(365)` ~433 ms, `GET /` ~350 ms) beside a fresh
      re-measurement of all three with any gap noted as a finding, splits
      inherent cost from defect, and states that taildash's 0.3 s probe of
      `GET /` is why it lists cash_lens as non-web.
- [ ] Every defect the document judges worth fixing has a `backlog` task on the
      board naming the ceiling it must bring the test down to.
- [ ] `mix precommit` passes.

## Out of Scope

- Any optimisation: batching, preloading, caching, memoising or restructuring
  `Forecast.project/2`, `Installments.account_installment_groups/2`, or the
  dashboard controller. Those are the follow-up tasks this one creates.
- Changing what the dashboard displays, or the forecast horizon.
- A committed benchmark/profiling mix task.
- Anything on the taildash side; this task only states the consequence.
