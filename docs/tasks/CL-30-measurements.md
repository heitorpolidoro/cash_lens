# CL-30 — Measurements and investigation record

Base commit: `a84f268`.

## How these numbers were taken

`./run` was live on the host for the whole of this task (it serves the app on
`localhost:4444` and holds the `cash_lens_pgdata` volume on port 5432), so the
compose stack was deliberately **not** started — see the warning in `AGENTS.md`
about two postmasters on one data directory. Everything below was therefore
measured on the host with

```
DATABASE_HOST=localhost DATABASE_PORT=5432 MIX_ENV=test mix test <path>
```

and, for the browser investigation, against the running dev app on
`localhost:4444`.

The timing harness was a throwaway ExUnit file (not committed) that seeded a
dataset comparable to the dev database — 4682 transactions over 21 months, 73
installment groups, 11 accounts — and then measured, median of 7 runs:

1. the cost of the per-row suggestion path over one page of 50 rows
   (`Enum.map(rows, &Transactions.suggest_installment_link/1)`), which is the
   work `index.html.heex:821` used to do inside the row comprehension;
2. wall time of a `load-more` event, which fetches and renders exactly one page
   of 50 rows, measured through `Phoenix.LiveViewTest.render_click/2`;
3. Phoenix's own `Replied in` line, read out of the captured LiveView log at
   `:debug` level.

## Before/after

Median of 7 runs in every row.

| Metric | Before (`a84f268`) | After | Note |
|---|---|---|---|
| Per-50-rows suggestion work during render | **24.3 ms**, ~150 queries (baseline recorded in the investigation) | **0.0 ms, 0 queries** | The template no longer calls `suggest_installment_link/1` at all; the zero-query assertion in `index_installment_suggestion_test.exs` proves it. |
| Per-50-rows suggestion work, re-measured on this host with the seeded dataset | 53.0 ms, 150 queries | **0.0 ms, 0 queries** | Same method, this machine's numbers; the 24.3 ms baseline above is the figure the expected result is stated against, and 0.0 ms is below it. |
| One page of 50 rows, full `load-more` round trip through `LiveViewTest` (wall time) | 248.7 ms | **177.8 ms** | Inflated by the test client's own HTML merge; only the ~71 ms delta is meaningful and it is entirely the removed per-row work. |
| `Replied in`, single-month filter (`?month=6&year=2026`) | 19.0 ms (seeded dataset) / 175 ms (dev dataset, investigation baseline) | 22.0 ms (seeded dataset) | Unchanged within noise — see below. |
| `Replied in`, "Todos os Períodos" | 17.0 ms (seeded dataset) / 555 ms (dev dataset, investigation baseline) | 19.0 ms (seeded dataset) | Unchanged within noise — see below. |

Why `Replied in` barely moves: Phoenix emits that line from the
`[:phoenix, :live_view, mount | handle_params | handle_event, :stop]` telemetry
event, which wraps **only the callback**. The template render — where the
per-row `suggest_installment_link/1` calls lived — happens after that event, so
the removed work was never inside the `Replied in` window to begin with. The
figures are recorded because the task asks for them; the win shows up in the
first three rows, not here. The remaining `Replied in` cost is the summary,
count and pending-badge queries `handle_params` runs, which this task does not
touch. The logger prints whole milliseconds, so ±3 ms between two runs of the
same code is the measurement floor.

## Infinite scroll reproduction

**Not reproduced.** `assets/js/app.js` is therefore unchanged:
`git diff a84f268..HEAD -- assets/js/app.js` produces no output.

Steps tried, all against the live dev app on `localhost:4444`:

- A dedicated, **visible** Chrome window was launched on its own profile with
  `--remote-debugging-port=9222 --window-size=1400,1000` and driven over CDP.
  The viewport was confirmed real before anything else was measured:
  `window.innerHeight = 913`, `window.innerWidth = 1400`,
  `document.visibilityState = "visible"`. This is the check the earlier
  observation failed — a hidden pane reports `innerHeight === 0`, which disables
  `IntersectionObserver` entirely and makes any such test vacuous.
- `load-more` events were counted at the wire, not in the app: CDP
  `Network.webSocketFrameSent` frames whose payload contains `load-more`.
- **"Todos os Períodos" (4682 transactions, 94 pages).** Scrolled to the bottom
  six times in a row, waiting 4 s after each scroll. Result: exactly **one**
  `load-more` frame per scroll (6 scrolls → 6 frames, rows 50 → 350), inter-frame
  gaps 4001/4022/4252/5669/6879 ms, i.e. one per deliberate scroll and never a
  burst.
- **Idle.** After the last scroll the page was left untouched for 10 s:
  **0** further `load-more` frames. Pages do not keep loading while the page
  sits idle.
- **Flick-scroll stress.** With a single-month filter, the sentinel was jiggled
  in and out of view ten times in a row (120 ms apart), which is what a real
  flick-scroll does to an `IntersectionObserver`: **0** extra `load-more`
  frames.
- **End of list.** With the September 2026 filter (95 transactions, two pages),
  one scroll to the bottom loaded the second page (rows 50 → 95), after which
  `document.getElementById("infinite-scroll-sentinel")` was `null`, the page
  showed "Fim do extrato", and three further scrolls to the bottom plus the
  flick-scroll stress plus 10 s idle produced **0** additional `load-more`
  frames. The sentinel does stop firing once `end_of_list?` is reached, exactly
  as the template comment claims.

Conclusion: the hook has no in-flight guard, but no chain-load behaviour could
be produced with a real viewport. Per the spec, the hook is left alone rather
than "fixed" against an unconfirmed defect.

## Dropdown open state across the row patch

The spec flags a stream pitfall: the suggestion reaches the row through
`stream_insert` of the annotated transaction, and a DaisyUI dropdown is opened
by focus, so the row patch could close the menu the user just opened.

Checked by hand in the same visible Chrome window, on the live dev app: for five
different rows, focusing and clicking the `#installment-menu-<id>` button and
waiting for the server reply left `document.activeElement === button`,
`dropdown.contains(document.activeElement) === true` and the
`.dropdown-content` menu visible (offsetHeight 3506). Opening the same row a
second time (the memoized path) behaved identically. **The focus-based dropdown
survives the patch**, so the client-side DaisyUI behaviour was kept and no
server-held "open row id" assign was needed.

The browser check could not exercise the `Vincular a …` label itself: under the
current `Installments.find_matching_group/1` — whose reversed `ILIKE` is
explicitly out of scope for this task — no transaction in the dev database
matches any of its 73 installment groups, so every row resolves to "no
suggestion". That path is covered by
`test/cash_lens_web/live/transaction_live/index_installment_suggestion_test.exs`
instead, which asserts the rendered label against
`Transactions.suggest_installment_link/1` itself.

## Credo baseline

Per-file finding counts from `mix credo --strict <file>`. The baseline column
was captured at `a84f268`, before any file was edited. `mix quality_check` is
unachievable in this repo (~23 pre-existing findings in untouched files), so the
bar is per file against this table.

`git diff --name-only a84f268..HEAD` limited to the files this task changes
reports exactly the three files below (the `.heex` template is excluded because
credo analyses only `.ex`/`.exs`).

| file | baseline findings | after findings |
|---|---|---|
| `lib/cash_lens_web/live/transaction_live/index.ex` | 1 | 1 |
| `lib/cash_lens/transactions/transaction.ex` | 0 | 0 |
| `test/cash_lens_web/live/transaction_live/index_installment_suggestion_test.exs` | 0 (new file) | 0 |

The single finding in `index.ex` is the pre-existing
`Function body is nested too deep (max depth is 2, was 5)` at
`handle_event/3`, untouched by this task.
