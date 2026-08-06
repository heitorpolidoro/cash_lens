# Month comparison design

## Problem

`MonthLive.Show` (`/months/:year/:month`) shows one month's income/expense
summary and category breakdown at a time, with ‹ › arrows to step to the
adjacent month. There's no way to see two months side by side to compare
them — the user has to flip back and forth, holding numbers in their head.

## Goal

Add a **Comparar** button to `/months/:year/:month` that opens a second,
independently-navigable month panel next to the current one, so both can be
read side by side.

## Non-goals

- Comparing more than two months at once.
- A dedicated month-picker UI for choosing the compare month (it always
  starts at the previous month; the user then uses that panel's own arrows
  to reach any other month).
- Any change to the underlying summary/breakdown queries in
  `CashLens.Transactions` — this is purely a presentation change reusing
  the exact same reads `MonthLive.Show` already performs.

## Architecture

### `MonthLive.MonthPanel` (new `Phoenix.LiveComponent`)

Everything currently rendered by `MonthLive.Show`'s `render/1` — the
header with ‹ › arrows, the "Ver todas as transações" link, the three
summary cards, and the two `breakdown_section`s (including the
expand-to-see-transactions behavior) — moves into this component
unchanged, just re-homed from `assigns` on the LiveView to `assigns` on
the component.

- **Props:** `id` (the DOM/component id — `"primary"` or `"compare"`),
  `year`, `month`.
- **Internal state:** `summary`, `breakdown`, `income_breakdown`, `prev`,
  `next`, `expanded_categories`, `category_transactions` — computed in
  `update/2` exactly as `MonthLive.Show.mount/3` computes them today.
- When `update/2` receives a `year`/`month` different from the component's
  previous assigns, it recomputes all of the above and resets
  `expanded_categories`/`category_transactions` to empty — matching
  today's behavior, where navigating to a new month is a fresh mount and
  naturally starts with nothing expanded.
- `toggle_category` is handled inside the component
  (`phx-target={@myself}`), so each panel's expanded state is fully
  isolated — expanding a category in one panel can never affect the other,
  because they're separate component instances with separate state.
- Navigation arrows render as `<.link patch={...}>` (not `navigate`), so
  stepping through months only triggers `handle_params` on the parent
  `MonthLive.Show`, never a full remount.

### `MonthLive.Show` (existing LiveView, trimmed down)

Owns only: parsing the primary year/month from the path (existing
fallback-redirect logic on invalid input, unchanged), parsing the optional
`compare` query param, and the open/close-comparison events. It renders
one or two `<.live_component module={MonthPanel} .../>`.

```elixir
def handle_params(%{"year" => y, "month" => m} = params, _uri, socket) do
  # existing year/month parsing + invalid-date redirect, unchanged
  compare = parse_compare_param(params["compare"])  # {year, month} | nil
  {:noreply, socket |> assign(:primary, %{year: year, month: month}) |> assign(:compare, compare)}
end

def handle_event("open_compare", _params, socket) do
  %{year: y, month: m} = socket.assigns.primary
  {py, pm} = prev_month(y, m)
  {:noreply, push_patch(socket, to: ~p"/months/#{y}/#{m}?compare=#{py}-#{pm}")}
end

def handle_event("close_compare", _params, socket) do
  %{year: y, month: m} = socket.assigns.primary
  {:noreply, push_patch(socket, to: ~p"/months/#{y}/#{m}")}
end
```

`prev_month/2`, `next_month/2`, and the `@month_names` list move to
`MonthPanel` (or a shared module) since the panel is what needs them for
its own arrows; `MonthLive.Show` only needs `prev_month/2` for the
"open_compare" default.

## URL scheme

- `/months/:year/:month` — the primary (left) panel. Unchanged from today.
- `?compare=YYYY-M` (e.g. `?compare=2026-6`) — optional. When present, a
  second (right) panel renders showing that month.
- The **primary panel's** arrows are `<.link patch={~p"/months/#{y}/#{m}?compare=..."}>`
  — they change the path, carrying the current `compare` param along
  unchanged (if any).
- The **compare panel's** arrows are `<.link patch={~p"/months/#{primary.year}/#{primary.month}?compare=#{y}-#{m}"}>`
  — they only change the query param, leaving the path untouched.
- Visiting a `?compare=...` URL directly (fresh load or shared link) opens
  both panels immediately, in the state the link encodes.
- "Fechar comparação" removes the `compare` param via `push_patch`, back
  to a single panel.

## UI / layout

- **Comparar** button sits next to the "Ver todas as transações" link in
  the header, visible only when `@compare` is `nil`.
- Once compare mode is open, that button is replaced by **Fechar
  comparação** (with a close/✕ icon), which collapses back to one panel.
- Two panels render in `<div class="grid grid-cols-1 lg:grid-cols-2 gap-6">`
  — side by side on wide screens (`lg:` breakpoint), stacked on narrow
  ones.
- The page container drops its current `max-w-4xl` constraint when a
  second panel is open, so the two panels can use the full width; a single
  panel keeps today's `max-w-4xl mx-auto` centering.

## Testing

All exercised through `Phoenix.LiveViewTest` against `MonthLive.Show`
(`MonthPanel` is a stateful `LiveComponent` and isn't mounted in
isolation):

- Clicking **Comparar** opens a second panel defaulted to the previous
  month, and the URL gains `?compare=<prev-year>-<prev-month>`.
- Clicking the compare panel's ‹ or › arrow changes only that panel's
  content and only the `compare` query param — the primary panel and path
  are unaffected.
- Clicking the primary panel's ‹ or › arrow changes the path (and thus
  which month is "primary") while an open `compare` param is preserved
  unchanged.
- Expanding a category in one panel does not expand the same category in
  the other panel.
- Loading `/months/2026/7?compare=2026-6` directly renders both panels
  already populated, with no extra click needed.
- Clicking **Fechar comparação** removes the second panel and the
  `compare` query param.
