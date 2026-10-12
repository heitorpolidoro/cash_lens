# CL-39 — Read each card's bill estimate once per card, not once per due-month

Base commit: `61f1d5b`. Figures re-measured 2026-10-11 (see "Baseline, two
columns" below).

## Scope

`Forecast.card_occurrences/2` is 415 of the dashboard's 492 queries and 342 of
its ~424 ms on the development database (`docs/tasks/CL-38-measurements.md`,
defects D1 and D2). Two repeats cause it, and this task removes both:

- **D1** — `Installments.account_installment_groups/2` issues one query per
  call, and is called once per sampled statement per estimated month. The query
  does not depend on the month at all: it loads every group touching the
  account and then filters parcels in Elixir with a pure predicate.
- **D2** — `Forecast.statement_for_month/2` asks for one due-month at a time,
  and `estimate_for_month/2` re-reads the *same* six-statement sample (whose
  window depends only on the account and today) once per due-month.

The fix is per-card prefetching inside the card-occurrence walk: for each card,
read the statements of the walked due-months once, read the estimate sample
once, read the card's installment groups once, and derive every due-month from
those three results in memory.

Out of scope: defects D3 (CL-40), D4 (CL-41) and D5 (CL-42); any change to what
the dashboard displays; the repo-wide `mix precommit` failures, which belong to
**CL-43** (a compile warning at `lib/cash_lens/imports.ex:136`, ~23 pre-existing
`credo --strict` findings, and two calendar-dependent test failures at
`test/cash_lens/forecast_test.exs:2283` and
`test/cash_lens_web/controllers/page_controller_test.exs:285`, both verified
still failing at `61f1d5b` and both independent of this task). No UI changes, so
**no HTML mockup is produced** — the page must render byte-for-byte the same
bills, estimates and parcel disclosures.

## Approach

### Behaviour

**Statements, once per card.** The walk over a card's due-dates must be driven
by one read of that card's statements over a **month-aligned** window covering
the walked due-months, and one read of its estimate sample (`due_date >=`
today − `30 * @history_months`, ordered `due_date` descending, limited to
`@estimate_sample`). Two reads per card; combining them into one is allowed but
not required.

The window's bounds are `Date.beginning_of_month/1` of the walk's first
due-date to `Date.end_of_month/1` of its last — *not* `[today, horizon_end]`.
This is what makes the prefetch equivalent to today's per-month reads, and the
difference is observable at both ends of the walk. At the lower end,
`card_due_dates/3` starts in the current month whenever `due_day >= today.day`,
and `statement_for_month/2` scans that whole month; a statement for that month
whose `due_date` is already past — a card whose `due_day` was changed, or an
imported bill with an off-cycle `due_date` — is returned today and would be
dropped by a `today` lower bound, moving the month out of the `:boleto` branch
(or out of "paid, no occurrence") and into the estimate branch. At the upper
end, the last due-date is `<= horizon_end` but its month extends past it (with
`due_day` 5 and today 2026-10-11, the last due-date is 2027-10-05, whose month
ends 2027-10-31 against a horizon end of 2027-10-11), so a statement due
2027-10-20 is found today and would be dropped by a `horizon_end` upper bound.
Neither case is reachable from the budget test's fixtures, since
`build_statements/2` derives every `due_date` from the card's own `due_day`;
the window is therefore a review criterion on the code, not something a test
will catch.

Per due-month, the statement selected from the prefetched result must be the
one today's `statement_for_month/2` returns — the maximum by
`{due_date, inserted_at}` among the statements whose `due_date` lands in that
month, so a month holding two statements still resolves to the same row. The
estimate sample is identical for every month of a card, so it is computed once
and reused; `variable_part/1`'s per-statement work stays as it is, including the
`statement_amount/1` fallback that reads transactions for a statement with a
null `total_a_pagar` (now reached once per sampled statement instead of once per
sampled statement per month — fewer queries, same values).

**Groups, once per card.** `Installments` gains an account-scoped load of the
groups touching an account, plus pure month-filtering on top of that result, and
`account_installment_groups/2` / `account_installment_total/2` keep their current
signatures and results by being expressed in terms of the two. The card walk
loads a card's groups once and derives, in Elixir, both the estimate's
`scheduled` total, each sampled statement's `installments` total, and the
`:estimado` occurrence's parcel disclosure. The account scoping must stay in the
query (`join: t in assoc(g, :transactions), where: t.account_id == ^account_id`)
— `test/cash_lens/forecast_scope_guard_test.exs` exists because a leaked scope
empties this read and silently drops the disclosure.

### Files touched

- `lib/cash_lens/forecast.ex` — per-card prefetch of the card's statements over
  the month-aligned window of the walked due-months, and of the estimate sample;
  `statement_for_month/2` and `estimate_for_month/2` take the prefetched rows
  instead of querying per month.
- `lib/cash_lens/installments.ex` — account-scoped group load plus pure
  month-filter/total helpers; the two public functions re-expressed over them.
- `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` — the three
  ceilings and their derivation comments, including dropping the per-card
  calendar delta for both groups to 0 and the `@..._per_card_due_month` cost
  constants that no longer describe the code.

### Test criteria

- The budget test is the primary proof: `installment_groups` ≤ 3,
  `credit_card_statements` ≤ 5, total ≤ 67, with the deltas for both groups at
  0 and every other ceiling unchanged.
- Behaviour preservation is proved by the *existing* tests passing **unchanged**
  — `test/cash_lens/forecast_test.exs` (`card_occurrences/2`, "card occurrence
  installment disclosure", "upcoming_bills/2"), `installments_test.exs`
  (`account_installment_total/2`, `account_installment_groups/2`), both scope
  guards, and `page_controller_test.exs`. An assertion edited to accommodate the
  refactor is a failure of this task, not a passing one; the two pre-existing
  calendar failures named above are the only admitted exceptions.
- No new test is required for the query-count claim: the budget test already
  measures it per table, which is the whole point of CL-38.

### Baseline, two columns

| Metric (fixture set) | Stated on the task / in CL-38 | Measured 2026-10-11 at `61f1d5b` |
|---|---:|---:|
| total | 282 | **283** |
| `installment_groups` | 177 | **177** |
| `credit_card_statements` | 47 | **47** |
| `transactions` | 19 | **20** |
| target total after this task | 66 | **67** |

**Finding — the target total is 67, not the 66 the task carries.** The two
large groups reproduce to the unit, but commit `61f1d5b` added one
`transactions` query (`spend_rate/4`'s covered-days probe), which the committed
test already reflects (`@total_ceiling 283 + @total_delta`,
`@transactions_ceiling 20`) while the task's expected results were written
against 282. The arithmetic is unchanged otherwise:
`283 − (177 − 3) − (47 − 5) = 67`.

Ceilings are written as `measured + delta`, the convention CL-38 established.
The delta is **0** for both groups after this task, because neither scales with
the due-month calendar any more: `installment_groups` becomes one read per card
plus `Installments.list_off_card_groups/0` (2 + 1 = 3) and
`credit_card_statements` two reads per card plus
`CreditCards.closed_without_statement/0` (4 + 1 = 5), none of which moves when
the current month's due-day falls on, before or after today. That is the margin
disappearing because the dependency did, not because it was dropped.

On the development database (4 open cards with a full cycle, 0 statements with a
null `total_a_pagar`, both verified today) the same change predicts
`installment_groups` 321 → 5, `credit_card_statements` 95 → 9, and `GET /` 492 →
90 queries.

**Wall clock is deliberately not an expected result.** `card_occurrences/2` is
342 ms of the page's 424 ms, so this is the one follow-up that could bring
`GET /` inside taildash's 0.3 s probe — but that is a hoped-for consequence, not
a checkable criterion: it depends on the development dataset and the host. Today
the page measured 0.58–0.94 s (median ≈ 0.71 s of 7) at load average 13.5, so
the 424 ms baseline does not even reproduce on this machine right now. The
query counts are deterministic; they are the contract.

## Expected Results

- [ ] `Forecast.card_occurrences/2` reads each card's statements once for the
      whole horizon and its estimate sample once per card, not once per
      due-month.
- [ ] An account's installment groups are read once per card, and each month's
      parcels are filtered in Elixir from that single result.
- [ ] `test/cash_lens_web/controllers/dashboard_query_budget_test.exs` passes
      with `@installment_groups_ceiling` at 3, `@credit_card_statements_ceiling`
      at 5, and the per-card calendar delta for both groups at 0.
- [ ] The same test passes with `@total_ceiling` at 67, derived in its comment
      as `283 − 174 − 42`.
- [ ] The dashboard shows the same bills, estimates and parcel disclosures:
      `mix test test/cash_lens/forecast_test.exs
      test/cash_lens/installments_test.exs
      test/cash_lens/forecast_scope_guard_test.exs
      test/cash_lens/installments_scope_guard_test.exs
      test/cash_lens_web/controllers/page_controller_test.exs` fails only at the
      two pre-existing calendar tests, with no assertion in those files changed.
- [ ] `mix format --check-formatted` passes and `mix credo --strict` on the three
      touched files reports at most the one pre-existing finding
      (`lib/cash_lens/forecast.ex:8`, alias order), which CL-43 owns.

## Out of Scope

- `mix precommit` as a whole: red at `61f1d5b` for three reasons this task does
  not introduce and must not touch. **CL-43** owns the repo-wide fix.
- Defects D3–D5, and the judged-not-worth-fixing duplicates listed in
  `docs/tasks/CL-38-measurements.md`.
- Any change to the fixture set in the budget test: the ceilings are only
  comparable to CL-38's if the dataset they are measured on is the same one.
