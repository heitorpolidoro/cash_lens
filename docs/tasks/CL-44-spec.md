# CL-44 — Make the month zebra striping stand out on the statements screen

## Scope
The statements list (`CreditCardStatementLive.Index`) shades alternate months with `bg-base-200/50`. In the light theme that is about 96% lightness at half opacity over a 98% page, so the band is effectively invisible; the dark theme is similarly faint. This task makes the month bands clearly distinguishable in both themes. The banding logic (`striped_by_month/1`, which flips on cycle change, not per row) is correct and unchanged.

Not covered: other screens that use `bg-base-200/50` for headers or cards, the installments screen zebra, row content, sorting, filters.

## Approach
Behavior: rows of a shaded month get a visibly stronger background than unshaded rows in both the `light` and `dark` themes. Text stays readable, and row hover stays distinguishable from the band. Default (option A in the mock): a solid fill one step darker, at the `bg-base-300/60` level. Option B adds a thin accent marker on the first row of each month. The operator picks; the spec defaults to A.

Files touched:
- `lib/cash_lens_web/live/credit_card_statement_live/index.ex` — change the shaded-row class in the `<tr :for={... striped_by_month ...}>`; update the adjacent comment if needed. If hover and band end up too similar, give `hover` a distinct treatment on shaded rows.
- `test/cash_lens_web/live/credit_card_statement_live_test.exs` — the `shaded_months/1` helper matches `bg-base-200` in the row tag (around line 1173). Update it to the new class so the month-striping test keeps asserting that whole months are shaded together.

Test criteria: the updated month-striping test passes against the new class, and the statements LiveView test file passes.

## Expected Results
- [ ] Shaded-month rows render the new stronger class, and no row renders `bg-base-200/50`.
- [ ] All rows of one month are shaded or all unshaded, and adjacent months differ (the updated striping test passes).
- [ ] Placeholder rows ("Ainda não fechou" / "Aguardando fatura") follow the same banding and stay non-clickable.
- [ ] In the mock, the shaded band is clearly visible against the unshaded rows in both light and dark themes.
- [ ] Hovering a statement row is visually distinct from the shaded band.

## Out of Scope
Changing the grouping rule, shading of other tables' headers, theme palette edits in `assets/css/app.css`.
