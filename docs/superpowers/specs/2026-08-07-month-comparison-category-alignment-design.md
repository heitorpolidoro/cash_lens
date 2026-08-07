# Month comparison: category row alignment design

## Problem

`/months/:year/:month` in comparison mode (see
[2026-08-06-month-comparison-design.md](2026-08-06-month-comparison-design.md))
shows two independent month panels side by side, each with its own
"Receitas por Categoria" / "Gastos por Categoria" tables. Each table sorts
its own categories by total, independently — so the same category can land
on completely different rows on each side, making side-by-side comparison
by eye hard.

## Goal

When comparison is active, align both panels' category rows on the same
line: row order follows the left (primary) panel; any category missing on
one side renders as a non-interactive "R$ 0,00" placeholder on that side,
in that row.

## Non-goals

- No change to a single panel's own category order/behavior when
  comparison is *not* active — this is purely a compare-mode addition.
- No change to how a category's total or percentage is computed — only
  which row it renders on, and whether a placeholder row is synthesized.
- No coupling of the two panels' expand/collapse state (already decided:
  clicking a category expands only that side, independently — see prior
  design's Q&A). A placeholder row is never expandable, since there is
  nothing to show — it represents zero transactions for that category on
  that side, that month.

## Ordering rule

Per section ("Receitas por Categoria" and "Gastos por Categoria",
independently):

1. Every category present in the **primary** (left) panel's own
   breakdown, in that breakdown's existing order (already sorted by total
   — descending magnitude — via
   `CashLens.Transactions.get_month_category_breakdown/2` /
   `get_month_income_breakdown/2`; unchanged).
2. Then, every category present in the **compare** (right) panel's
   breakdown but *not* in the primary's, in the compare panel's own
   existing order.

Both panels render every row in this exact combined order. A category
missing from a given side's own breakdown renders as a placeholder row on
that side: name and (if applicable) fixed/variable label still shown
(taken from whichever side actually has the category), amount rendered as
"R$ 0,00" in a muted/dimmed style, no expand chevron, not clickable.

"Sem categoria" (`category_id: nil`, when present) participates in this
same ordering like any other row — it's just another entry with a `nil`
id, already how both panels' breakdown queries represent it today.

## Architecture

`MonthLive.Show` is the only place that has both months' identity
(`@primary`, `@compare`), so it's the natural place to compute the
combined row order. Each `MonthPanel` LiveComponent keeps owning its own
data fetch and its own expand/collapse state exactly as today — nothing
about panel isolation changes.

- When `@compare` is present, `Show` additionally calls
  `Transactions.get_month_category_breakdown/2` and
  `get_month_income_breakdown/2` for **both** months (yes, this duplicates
  the query each `MonthPanel` already runs for its own real data — a
  second, cheap, indexed read, traded for keeping the two panels'
  LiveComponent state fully independent rather than plumbing a
  parent-to-child data callback).
- From those four result sets, `Show` builds two ordered lists of `%{category_id, name, type}`
  (one for "credit"/income, one for "debit"/expense) per the rule above,
  and passes each as a new prop, `row_order`, to **both** panels (same
  list on both sides, so they align).
- `MonthPanel` accepts `row_order` as an optional prop (`nil` when
  comparison is off — today's behavior, completely unchanged rendering
  path). When present, for each section it renders, it walks `row_order`
  instead of its own `breakdown`/`income_breakdown` list: for each entry,
  if a matching `category_id` exists in its own data, render that real
  row (unchanged markup/behavior); if not, render the new placeholder row
  variant.

## UI

The placeholder row: same table row structure (category name + optional
fixed/variable/"sem categoria" sub-label, same as a real row), but:

- No chevron icon (▸/▾) — nothing to expand.
- `R$ 0,00` and the row text rendered in a muted/opacity-reduced style,
  visually distinct from a real (interactive) row.
- No `phx-click`/`phx-target` — not clickable.
- The %-of-total bar renders empty (0%), consistent with a real R$ 0,00
  row — no special-casing needed there.

**Known, accepted limitation:** expanding a category's transactions on one
side (already independent per side, per the prior design) grows that
side's table at that point, which desyncs the two tables' vertical
alignment below that row until it's collapsed again. This is the accepted
cost of keeping both sides independently expandable — confirmed
acceptable; no mitigation planned.

## Testing

Exercised via `Phoenix.LiveViewTest` against `MonthLive.Show`, in
comparison mode:

- A category present in both months' breakdowns appears once, at the
  primary's position, with each side's real total.
- A category present only in the primary's breakdown appears with a real
  value on the primary side and a `R$ 0,00` placeholder (non-interactive)
  on the compare side.
- A category present only in the compare's breakdown appears *after* all
  of the primary's own categories, with `R$ 0,00` on the primary side and
  a real value on the compare side.
- "Sem categoria" participates in the same alignment as any other row.
- Both the income and expense sections are aligned independently of each
  other.
- Outside comparison mode (`@compare` is `nil`), a single panel's category
  order and rendering are unchanged from before this feature — no
  placeholder rows ever appear.
