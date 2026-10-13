# CL-48 — Show installment commitments (financiamento, consórcio, empréstimo) on the Contas Recorrentes screen

## Scope
`deactivate_superseded_items/0` switches off a category's recurring item when every transaction in it is linked to an installment group, so the forecast does not count the spend twice. Side effect: financing, consórcio and loans vanish from Contas Recorrentes although they are monthly bills. This task keeps that deactivation untouched (the forecast is unchanged) and makes the screen also list off-card installment groups, read straight from the group, as read-only rows.

Not covered: any change to forecast projection, to `deactivate_superseded_items/0`, or to the group registration screens; editing a group from this screen; deleting existing inactive recurring items (the operator does that with the existing delete button once the rows are visible).

## Approach
Behavior:
- A new Forecast read function returns the commitment rows for the screen, built from `Installments.list_off_card_groups/0` (the same membership the forecast's "Recorrência temporária" uses, so card installments never appear). Groups whose last parcel date (`Installments.last_installment_date/1`) is before the first day of the current month are omitted (finished). Each row carries: label (`description_pattern`), commitment type, parcel position of the current month (`Installments.parcel_position/2`; 1 when the group has not started yet), total parcels, end date, day of month (day of `start_date`), and parcel value (`Installments.parcel_value/1`, shown as an expense, negative).
- The LiveView renders these rows in the same table (after the recurring items, visually distinct) with a "Parcelado" badge, "12 de 48", end date, day and value, and no toggle/resync/edit/delete buttons.
- The "Comprometido por mês" total stays the sum of active recurring items only (commitments already reach the forecast through the temporary recurrences). The page copy says so briefly.
- The empty state shows only when both lists are empty.
- `sync_all/0` creates nothing for a fixed category that `fully_grouped_category?/1` reports as covered by installment groups, so a deleted item is not recreated. Existing items are handled as today.

Files touched:
- `lib/cash_lens/forecast.ex` — new commitment-rows function; `sync_one/3` nil-item clause skips fully grouped categories.
- `lib/cash_lens_web/live/recurring_item_live/index.ex` — load and render commitment rows, empty-state condition.
- `test/cash_lens/forecast_test.exs`, `test/cash_lens_web/live/recurring_item_live_test.exs` — coverage below.
- `docs/tasks/CL-48-mock.html` — visual reference.

Test criteria: an off-card financing/consórcio/empréstimo group appears with badge, "N de M", end date, day and value, and has no `toggle-`/`edit-`/`delete-` buttons; a card-linked group and a finished group do not appear; monthly total unchanged by commitments; with a fully grouped fixed category and no recurring item, `sync_all/0` creates none; existing forecast tests still pass.

## Expected Results
- [ ] An off-card installment group (financing, consórcio or empréstimo) appears on `/recurring_items` with a "Parcelado" badge, even when its category's recurring item is inactive.
- [ ] The row shows the current parcel position as "N de M", the end date, the day of month and the parcel value.
- [ ] Commitment rows render no activate/deactivate, edit, resync or delete controls.
- [ ] Credit-card installment groups and groups whose last parcel is before the current month do not appear.
- [ ] "Comprometido por mês" ignores commitment rows, and `deactivate_superseded_items/0` and forecast results are unchanged.
- [ ] `sync_all/0` creates no recurring item for a fixed category whose transactions are all linked to installment groups.
- [ ] `mix test` passes with new tests for the listing and the sync rule.

## Out of Scope
Deleting existing inactive recurring items (manual, via the existing button); editing groups from this screen.
