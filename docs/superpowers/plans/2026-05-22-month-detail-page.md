# Month Detail Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a dedicated `/months/:year/:month` page showing a month's summary cards, category breakdown table with percentages, and a link to the filtered transaction list.

**Architecture:** New `MonthLive.Show` LiveView that reads `year`/`month` from URL params, fetches a new `get_month_category_breakdown/2` from the Transactions context, and renders summary cards + a sortable category table. Dashboard's history section gets clickable month links to this page.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Ecto, daisyUI, `CashLensWeb.Formatters.format_currency/1`

---

### Task 1: Add `get_month_category_breakdown/2` to Transactions context

**Files:**
- Modify: `lib/cash_lens/transactions.ex`

- [ ] **Step 1: Add the function after `get_monthly_summary/2`**

```elixir
@doc """
Returns spending broken down by top-level category for a given month/year.
Excludes transfers, initial values, and reimbursed transactions.
Each entry: %{name: str, type: str, total: Decimal, parent_name: str|nil}
"""
def get_month_category_breakdown(year, month) when is_integer(year) and is_integer(month) do
  first = Date.new!(year, month, 1)
  last = Date.end_of_month(first)

  from(t in Transaction,
    join: c in assoc(t, :category),
    left_join: p in assoc(c, :parent),
    where: t.amount < 0,
    where: t.date >= ^first and t.date <= ^last,
    where: c.slug not in ["initial_value", "transfer"],
    where: is_nil(t.reimbursement_link_key),
    group_by: [
      fragment("COALESCE(?, ?)", p.name, c.name),
      fragment("COALESCE(?, ?)", p.id, c.id),
      c.type
    ],
    select: %{
      name: fragment("COALESCE(?, ?)", p.name, c.name),
      category_id: fragment("COALESCE(?, ?)", p.id, c.id),
      type: c.type,
      total: sum(fragment("ABS(?)", t.amount))
    },
    order_by: [desc: sum(fragment("ABS(?)", t.amount))]
  )
  |> Repo.all()
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile 2>&1 | grep -E "error|warning"
```
Expected: no errors.

- [ ] **Step 3: Smoke-test in iex**

```bash
export $(cat .env | xargs) && mix run -e '
  today = Date.utc_today()
  result = CashLens.Transactions.get_month_category_breakdown(today.year, today.month)
  IO.inspect(Enum.take(result, 3), pretty: true)
'
```
Expected: list of maps with `name`, `type`, `total`, `category_id` keys.

---

### Task 2: Create the `MonthLive.Show` LiveView

**Files:**
- Create: `lib/cash_lens_web/live/month_live/show.ex`

- [ ] **Step 1: Create the file**

```elixir
defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Transactions

  @month_names ~w(Janeiro Fevereiro Março Abril Maio Junho
                  Julho Agosto Setembro Outubro Novembro Dezembro)

  @impl true
  def mount(%{"year" => year_str, "month" => month_str}, _session, socket) do
    year = String.to_integer(year_str)
    month = String.to_integer(month_str)

    summary = Transactions.get_monthly_summary(Date.new!(year, month, 1))
    breakdown = Transactions.get_month_category_breakdown(year, month)

    total_expenses = summary.expenses

    breakdown_with_pct =
      Enum.map(breakdown, fn row ->
        pct =
          if Decimal.gt?(total_expenses, 0),
            do: row.total |> Decimal.div(total_expenses) |> Decimal.mult(100) |> Decimal.round(1),
            else: Decimal.new("0")

        Map.put(row, :pct, pct)
      end)

    prev = prev_month(year, month)
    next = next_month(year, month)

    {:ok,
     socket
     |> assign(:year, year)
     |> assign(:month, month)
     |> assign(:month_name, Enum.at(@month_names, month - 1))
     |> assign(:summary, summary)
     |> assign(:breakdown, breakdown_with_pct)
     |> assign(:prev, prev)
     |> assign(:next, next)}
  end

  defp prev_month(year, 1), do: {year - 1, 12}
  defp prev_month(year, month), do: {year, month - 1}

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-8 space-y-8 max-w-4xl mx-auto">
      <%!-- Header with prev/next navigation --%>
      <div class="flex items-center justify-between">
        <.link navigate={~p"/months/#{elem(@prev, 0)}/#{elem(@prev, 1)}"} class="btn btn-ghost btn-sm">
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>

        <div class="text-center">
          <h1 class="text-3xl font-black uppercase tracking-tighter">
            {@month_name} {@year}
          </h1>
          <.link
            navigate={~p"/transactions?month=#{@month}&year=#{@year}"}
            class="text-xs opacity-50 hover:opacity-100 underline"
          >
            View all transactions →
          </.link>
        </div>

        <.link navigate={~p"/months/#{elem(@next, 0)}/#{elem(@next, 1)}"} class="btn btn-ghost btn-sm">
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>

      <%!-- Summary cards --%>
      <div class="grid grid-cols-3 gap-4">
        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1">
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Income</p>
          <p class="text-2xl font-black text-success">{format_currency(@summary.income)}</p>
        </div>
        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1">
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Expenses</p>
          <p class="text-2xl font-black text-error">{format_currency(@summary.expenses)}</p>
        </div>
        <div class={[
          "bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1",
          if(Decimal.gt?(@summary.income, @summary.expenses), do: "border-success/30", else: "border-error/30")
        ]}>
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Balance</p>
          <p class={[
            "text-2xl font-black",
            if(Decimal.gt?(@summary.income, @summary.expenses), do: "text-success", else: "text-error")
          ]}>
            {format_currency(Decimal.sub(@summary.income, @summary.expenses))}
          </p>
        </div>
      </div>

      <%!-- Category breakdown --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-black uppercase tracking-tight text-sm">Spending by Category</h2>
          <span class="text-xs opacity-50">{length(@breakdown)} categories</span>
        </div>

        <div :if={@breakdown == []} class="px-6 py-12 text-center opacity-40 text-sm">
          No expenses recorded for this month.
        </div>

        <table :if={@breakdown != []} class="table table-sm w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Category</th>
              <th>Type</th>
              <th class="text-right">Amount</th>
              <th class="text-right w-24">% of total</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @breakdown do %>
              <tr class="hover">
                <td class="font-semibold">{row.name}</td>
                <td>
                  <span class={[
                    "badge badge-xs font-bold uppercase",
                    if(row.type == "fixed", do: "badge-info", else: "badge-warning")
                  ]}>
                    {row.type}
                  </span>
                </td>
                <td class="text-right font-mono text-error">{format_currency(row.total)}</td>
                <td class="text-right">
                  <div class="flex items-center justify-end gap-2">
                    <div class="w-16 bg-base-300 rounded-full h-1.5">
                      <div
                        class="bg-primary h-1.5 rounded-full"
                        style={"width: #{min(Decimal.to_float(row.pct), 100)}%"}
                      >
                      </div>
                    </div>
                    <span class="w-10 text-right opacity-70">{row.pct}%</span>
                  </div>
                </td>
                <td class="text-right">
                  <.link
                    navigate={~p"/transactions?month=#{@month}&year=#{@year}&category_id=#{row.category_id}"}
                    class="btn btn-ghost btn-xs opacity-50 hover:opacity-100"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </.link>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile 2>&1 | grep -E "error|warning"
```
Expected: no errors.

---

### Task 3: Register the route

**Files:**
- Modify: `lib/cash_lens_web/router.ex`

- [ ] **Step 1: Add route alongside other live routes**

Find the block with `live "/transactions"` and add:

```elixir
live "/months/:year/:month", MonthLive.Show, :show
```

- [ ] **Step 2: Verify compile + route exists**

```bash
mix compile 2>&1 | grep -E "error|warning"
mix phx.routes 2>/dev/null | grep month
```
Expected: `GET  /months/:year/:month  CashLensWeb.MonthLive.Show :show`

---

### Task 4: Add clickable month links from the dashboard

**Files:**
- Modify: `lib/cash_lens_web/live/` (find the dashboard/home LiveView)

- [ ] **Step 1: Find the dashboard file**

```bash
find lib/cash_lens_web/live -name "*.ex" | xargs grep -l "get_historical_summary\|historical" 2>/dev/null
```

- [ ] **Step 2: Find where monthly history rows are rendered in the dashboard template**

Look for where month/year are displayed in a table or list in the dashboard heex template.

- [ ] **Step 3: Wrap the month/year display in a `<.link navigate>`**

Find the cell rendering the month name (e.g. `item.month/item.year`) and wrap it:

```heex
<.link navigate={~p"/months/#{item.year}/#{item.month}"} class="hover:underline font-bold">
  {month_name(item.month)} {item.year}
</.link>
```

Add the helper function in the LiveView module:

```elixir
defp month_name(m) do
  ~w(Jan Fev Mar Abr Mai Jun Jul Ago Set Out Nov Dez) |> Enum.at(m - 1)
end
```

- [ ] **Step 4: Compile and verify**

```bash
mix compile 2>&1 | grep -E "error|warning"
```

---

### Task 5: Manual smoke test

- [ ] Start the server: `export $(cat .env | xargs) && mix phx.server`
- [ ] Navigate to `/months/2025/3` — should show March 2025 with summary cards and category table
- [ ] Click prev/next arrows — should navigate to adjacent months
- [ ] Click "View all transactions →" — should open `/transactions?month=3&year=2025`
- [ ] Click a category's arrow icon — should open transactions filtered by that category + month
- [ ] Navigate to an empty month — should show "No expenses recorded" message
- [ ] Dashboard month links should navigate to the detail page
