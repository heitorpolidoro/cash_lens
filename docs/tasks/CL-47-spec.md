# CL-47 — Sync must switch off recurring items whose bill stopped

## Scope
`Forecast.sync_all/0` must deactivate an existing, non-manually-edited recurring item whose category has no recent occurrence, even when the 6-month window has already shrunk below the minimum history. Today `suggest_for_category/1` checks minimum history first, so a bill that stopped loses its old rows from the window, returns `:insufficient_history`, and `sync_one/3` leaves the item active (it keeps showing as overdue, e.g. "igreja").

Not covered: creating items (a new category still needs the minimum history and a recent occurrence), manually edited items (still untouched), `resync_item/1` semantics, the staleness cut-off (first of last month), and any UI change.

## Approach
Behavior:
- For an existing item, when the suggestion is `:insufficient_history`, the sync checks the category's latest cash-account transaction in the window. If there is none (zero rows) or the latest is older than the staleness cut-off, the item is deactivated and counted in `deactivated`. If the latest is recent (e.g. a single recent transaction), the item is left untouched, as today.
- An already inactive item is not counted again.
- The zero-row case must not crash: the staleness check uses `Enum.max_by` on rows, which fails on an empty list.
- New categories (no item) behave exactly as before: nothing is created for `:insufficient_history` or `:no_recent_occurrence`.
- Preferred shape: keep `suggest_for_category/1` return values unchanged (existing tests pin them, including few-row cases returning `:insufficient_history`) and add the stale/empty check in the existing-item branch of `sync_one/3`, reusing the cut-off logic of `stale?/2` made safe for empty input. Do not duplicate the cut-off computation.

Files touched:
- `lib/cash_lens/forecast.ex`: existing-item `:insufficient_history` branch of `sync_one/3` deactivates when stale or empty; staleness helper handles an empty list; update the `sync_all/0` doc.
- `test/cash_lens/forecast_test.exs`: new `sync_all` tests.

Test criteria:
- Existing active item, one old transaction left in the window (below minimum, older than cut-off): `sync_all` returns `deactivated: 1` and the item is inactive.
- Existing active item, zero transactions in the window: deactivated, no exception.
- Existing active item, one recent transaction: untouched (`deactivated: 0`, still active).
- Manually edited item with the same stale history: untouched.
- Category with no item and stale/insufficient history: nothing created.
- Existing suite stays green.

## Expected Results
- [ ] `sync_all/0` deactivates an existing item whose only window transaction is older than last month's first day, returning `deactivated: 1`.
- [ ] `sync_all/0` deactivates an existing item with zero transactions in the window without raising.
- [ ] `sync_all/0` leaves an existing item with a single recent transaction active and returns `deactivated: 0`.
- [ ] `sync_all/0` leaves a manually edited item active regardless of its history.
- [ ] `sync_all/0` creates no item for a category without one when history is insufficient or stale.
- [ ] `mix test test/cash_lens/forecast_test.exs` passes, including the new tests.

## Out of Scope
Changing `suggest_for_category/1` return contracts, `resync_item/1`, UI.
