# CL-30 — Speed up the transactions screen by removing per-row work from render

## Scope

Covers the transactions index screen (`CashLensWeb.TransactionLive.Index`): stop resolving
the installment-link suggestion for every rendered row, and resolve it on demand when the
row's "Ações" installment dropdown is opened. Also covers a *reproduce-first* investigation
of the `InfiniteScroll` hook in `assets/js/app.js`, and recording before/after measurements.

Does **not** cover: batching the suggestion for the whole page (explicitly rejected — on
demand is the chosen design), fixing the reversed `ILIKE` in
`CashLens.Installments.find_matching_group/1`, adding indexes, changing page size, changing
`CashLens.Transactions.suggest_installment_link/1`'s own contract or its existing tests, or
any other screen.

## Approach

### Behavior

1. Rendering the transactions index (any filter, any page) must issue **zero** queries against
   `installment_groups`. Today one `<% suggestion = CashLens.Transactions.suggest_installment_link(transaction) %>`
   per row (index.html.heex:821) costs ~24.3 ms and ~150 queries for 50 rows, entirely for a
   dropdown that renders closed.
2. Clicking a row's installment ("Grupo de Parcelamento") button resolves the suggestion for
   that one transaction and renders it in the open menu with the same text and data as today:
   `Vincular a <group_name>? (<next_installment>/<total_installments>)`, wired to the existing
   `link_installment` event with the same `phx-value-id` / `phx-value-group_id`. No suggestion
   entry is rendered when the matched group is completed or when nothing matches. The static
   list of `@installment_groups` and the "Nenhum grupo encontrado" fallback keep rendering
   exactly as they do now, without any query.
3. Between the click and the reply the menu shows a neutral placeholder (e.g. "Buscando
   sugestão…"), so the menu is never visually empty.
4. The suggestion is memoized per transaction for the lifetime of the LiveView: opening the
   same row's menu a second time issues no further query. Linking or unlinking a transaction
   invalidates that transaction's memo entry.
5. `CashLens.Transactions.suggest_installment_link/1` stays as it is and remains the single
   place the suggestion is computed — it moves from the template to the LiveView.

### Files touched

- `lib/cash_lens_web/live/transaction_live/index.html.heex` — remove the in-template call;
  put `phx-click="load_installment_suggestion"` + `phx-value-id` on the dropdown button;
  render the suggestion/placeholder from the transaction's resolved suggestion instead.
- `lib/cash_lens_web/live/transaction_live/index.ex` — new `handle_event("load_installment_suggestion", …)`
  that checks the memo, calls `Transactions.suggest_installment_link/1` on a miss, stores the
  result (including `nil`, so a miss is not re-queried) and `stream_insert`s the annotated row;
  new assign holding the memo, initialised in `mount/3`; memo entry dropped in the existing
  `link_installment` / `unlink_installment` handlers.
- `lib/cash_lens/transactions/transaction.ex` — one virtual field carrying the resolved
  suggestion onto the streamed row, in the same spirit as the existing `suggested_category`.
- `assets/js/app.js` — only if the chain-load defect is reproduced (see below).
- `test/cash_lens_web/live/transaction_live/index_installment_suggestion_test.exs` — new.
- `docs/tasks/CL-30-measurements.md` — new; measurements and the hook investigation record.

Note the stream pitfall: rows already rendered are **not** re-rendered when an unrelated
assign changes, because `@streams.transactions` only carries pending inserts. The suggestion
must therefore reach the row through `stream_insert` of the (annotated) transaction, not by
reading a socket assign inside the row comprehension. Verify by hand in a browser that the
DaisyUI focus-based dropdown stays open across that row patch; if it closes, drive the open
state from the server instead (an assign holding the open row id, rendered as
`<details open={…}>`), and record which of the two was used in the measurements doc.

### Test criteria

A new LiveView test file must, using a `[:cash_lens, :repo, :query]` telemetry handler that
counts queries whose SQL mentions `installment_groups`:

- assert the count is `0` for a full render of a page of transactions that includes a row
  whose description matches an existing `InstallmentGroup.description_pattern`;
- assert that `render_click` on that row's installment button produces the
  `Vincular a <pattern>? (<n>/<total>)` label with the correct group, next installment number
  and total, and that the query count is now greater than zero;
- assert a transaction whose matched group is already completed produces no such label;
- assert that clicking the same button a second time does not increase the query count
  (memoization).

Existing tests for `suggest_installment_link/1` (`test/cash_lens/transactions_test.exs:146`
and `:163`) must keep passing untouched.

### Infinite scroll — reproduce before fixing

The `InfiniteScroll` hook (`assets/js/app.js`, ~line 122) pushes `load-more` from an
`IntersectionObserver` with no in-flight guard. This defect is **unconfirmed**: the earlier
observation could not be reproduced because the browser pane was hidden and
`window.innerHeight` was 0, which disables `IntersectionObserver` entirely. So: reproduce it
first with a **visible** viewport — open the transactions screen with "Todos os Períodos",
scroll to the bottom, and watch the server logs for `load-more` handling. If several
`load-more` events fire for one sentinel intersection, or pages keep loading while the page
sits idle, add an in-flight flag set before `pushEvent` and cleared in the `pushEvent` reply
callback, and confirm the sentinel stops firing once `end_of_list?` unmounts it. **If the
behavior does not reproduce, leave the hook unchanged** and record that outcome — "unchanged"
means `git diff a84f268..HEAD -- assets/js/app.js` produces no output, where `a84f268` is this
task's base commit. Do not "fix" a defect nobody confirmed.

### Measurements

Record in `docs/tasks/CL-30-measurements.md`: median wall time for rendering 50 rows before
and after (same method as the investigation — median of 7 runs), and Phoenix's own
"Replied in" figure before and after for a single-month filter and for "Todos os Períodos".
Baselines already measured: 24.3 ms / ~150 queries per 50 rows; 175 ms one month; 555 ms
"Todos os Períodos".

### Environment and quality bar

- Tests run as `docker compose exec app mix test`. Before starting the container stack, check
  for a live `./run` (`docker ps --filter name=cash_lens-db-native`, `pgrep -f 'bash ./run'`)
  and stop it — the two must never hold the `cash_lens_pgdata` volume at the same time.
- `mix quality_check` is unachievable here (~23 pre-existing credo findings in untouched
  files). The bar is **no new credo findings in touched files**, stated per file against a
  recorded baseline. Credo only analyses `.ex`/`.exs`, so the three files in question are
  `lib/cash_lens_web/live/transaction_live/index.ex`,
  `lib/cash_lens/transactions/transaction.ex` and
  `test/cash_lens_web/live/transaction_live/index_installment_suggestion_test.exs` (the `.heex`
  template is out of credo's reach). Before changing anything, run
  `docker compose exec app mix credo --strict <file>` for each of the first two at the base
  commit `a84f268` and record the finding count in a table in `docs/tasks/CL-30-measurements.md`
  under a heading `## Credo baseline`, one row per file with columns *file*, *baseline findings*,
  *after findings*; the new test file's baseline is 0 by definition. The after count must not
  exceed the baseline for any file. If the set of `.ex`/`.exs` files reported by
  `git diff --name-only a84f268..HEAD` differs from these three, the table must cover that set
  instead.
- `test/cash_lens_web/live/transaction_live/index_coverage_test.exs:170` and
  `test/cash_lens_web/live/forecast_live_test.exs:554` fail on the host **before** any change
  here; they are pre-existing and must not be attributed to this work.

![Mockup](CL-30-mock.html)

## Expected Results

- [ ] No `suggest_installment_link` call remains in `index.html.heex`; the new
      `load_installment_suggestion` event appears in both the template and the LiveView.
- [ ] A new LiveView test asserts zero `installment_groups` queries for a full page render.
- [ ] The same test asserts the on-open label matches `suggest_installment_link/1`, and that
      the query count then rises above zero.
- [ ] The same test covers the completed-group case (no label) and memoization (second open
      adds no query).
- [ ] `test/cash_lens/transactions_test.exs` still passes untouched.
- [ ] `docs/tasks/CL-30-measurements.md` records before/after timings, with the after median
      per 50 rows below the 24.3 ms baseline.
- [ ] `docs/tasks/CL-30-measurements.md` records the infinite-scroll reproduction attempt;
      if not reproduced, `git diff a84f268..HEAD -- assets/js/app.js` is empty.
- [ ] `docs/tasks/CL-30-measurements.md` carries a `## Credo baseline` table naming each
      changed `.ex`/`.exs` file with its baseline and after finding counts, and re-running
      `mix credo --strict` per file matches.

## Out of Scope

The reversed `ILIKE` in `find_matching_group/1`, batching, indexes, page size, and every
screen other than the transactions index.
