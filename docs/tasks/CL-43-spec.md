# CL-43 — Make mix precommit green again

## Scope
Make `mix precommit` pass at HEAD: the compile warning, the Credo strict findings, and two calendar-dependent tests. Also decide, and record in this spec's outcome, whether the dropped-statement behaviour is a lib defect. Not covered: any other behaviour change, new Credo checks, or loosening Credo globally.

## Approach
Behavior and files touched:

1. `lib/cash_lens/imports.ex`: move the catch-all `put_import_root/1` clause next to its other clauses (currently split by `unwrap_quote/2` and its helper). No behaviour change.
2. Credo: `mix credo --strict` currently reports about 23 findings (alias ordering in forecast.ex, credit_cards.ex, page_controller.ex, parsers/ingestor.ex; nesting depth and cyclomatic complexity in accounting.ex, credit_cards.ex, parsers/directory_importer.ex, transfer_matcher.ex, mix/tasks/cash_lens.import.ex; nested-module aliasing in credit_cards.ex, the migrate_ourocard_txt task and migrate_credit_card_transfers_test.exs; `length/1` in test/cash_lens/accounting_test.exs:243). Fix each by behaviour-preserving refactor (alias ordering, extracting private helpers, aliasing, `assert x != []`). Where a refactor is disproportionate (a large complexity-14 function such as `create_statement`), add a `.credo.exs` that keeps the default strict config and disables only that check for only that file/function via `# credo:disable-for-next-line` or a `files.excluded` entry, with a one-line justification comment. No blanket check disabling.
3. Tests `test/cash_lens/forecast_test.exs` (~line 2283, "a real unpaid statement is listed as a bill") and `test/cash_lens_web/controllers/page_controller_test.exs` (~line 285): stop pinning `due_day: 10`. Let `due = Date.add(Date.utc_today(), 4)` (it may fall in next month; that is fine). The statement's `due_date` is `due` unchanged. The card's `due_day` is exactly `min(due.day, 28)`: the cap is 28 so the value is valid in every month, and no other derivation is allowed. When `due.day` is 29-31 the card's `due_day` therefore differs from the statement's date; the tests must still pass, because item 4 lists a real unpaid statement regardless of `due_day`. Other tests in those files that use `due_day: 10` for estimate-based assertions are checked for the same flakiness and fixed likewise if they fail on a simulated date.
4. Decision on behaviour (lib defect, fix it; mandatory, no fallback): `Forecast.card_due_dates/3` derives candidate dates from `due_day` only, so an unpaid real statement whose `due_date` is still ahead (e.g. shifted for a weekend or entered manually) is ignored once `due_day` of that month has passed. A real, unpaid statement with `due_date` in `[today, horizon_end]` must be listed as a bill regardless of the card's `due_day`; the estimate for a month must not be produced when a real statement already covers that month (no double count). Change is in `lib/cash_lens/forecast.ex` (`card_account_occurrences/3` / `card_due_dates/3`), restructuring the walk if needed. The task is not done without this fix.

Test criteria: a forecast test with the card's `due_day` earlier than today's day-of-month and an unpaid statement due in 4 days asserts the bill is listed once (statement id present, no `:estimado` duplicate for that month); the two repaired tests are run with the clock-sensitive input varied (e.g. by constructing dates for day 1, 15 and 31 of a month where practical) or by construction independent of the day.

## Expected Results
- [ ] `mix compile --warnings-as-errors` succeeds, and the `put_import_root/1` tests pass unchanged.
- [ ] `mix credo --strict` exits 0, with any exception limited to a justified, narrowly scoped entry in a new `.credo.exs`.
- [ ] The forecast_test and page_controller_test "unpaid statement listed as a bill" tests set `due_day` to `min((today + 4).day, 28)` with the statement due on `today + 4`, and pass on any day of the month.
- [ ] A new forecast test shows an unpaid statement due in the window is listed once even when the card's `due_day` has already passed this month.
- [ ] `mix precommit` exits 0 and `mix test` is green.

## Out of Scope
Behaviour changes beyond the statement-listing fix; CL-38 work.
