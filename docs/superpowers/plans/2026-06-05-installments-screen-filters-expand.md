# Installments Screen — Filters, Expandable Rows & Last-Parcel Column — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add search filters, expandable parcel rows, and a "Última Parcela" (last-installment month/year) column to the installment groups screen.

**Architecture:** Two small read-only context functions in `CashLens.Installments`, plus enhancements to the `InstallmentLive.Index` LiveView (inline render). Filtering is done in-memory over the already-small list of active groups. No schema changes.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto, daisyUI/Tailwind, ExUnit.

---

## File Structure

- `lib/cash_lens/installments.ex` — add `last_installment_date/1` and `list_group_transactions/1` (read-only helpers).
- `lib/cash_lens_web/live/installment_live/index.ex` — add filters, expandable rows, last-parcel column, and supporting private helpers.
- `test/cash_lens/installments_test.exs` — context tests.
- `test/cash_lens_web/live/installment_live_test.exs` — LiveView tests.

Reused helpers (no change): `CashLens.Installments.add_months/2` (public), `CashLensWeb.Formatters.month_label/1` (abbreviated month, e.g. "Mai"), `format_currency/1`, `format_date/1`.

`get_group_with_progress/1` returns the group struct merged with `:paid_count`, `:remaining_count`, `:is_completed`, `:is_finished`. The progress map carries `description_pattern`, `total_amount` (Decimal | nil), `installments` (integer), `start_date` (Date), `id`.

---

## Task 1: Context — `last_installment_date/1`

**Files:**
- Modify: `lib/cash_lens/installments.ex`
- Test: `test/cash_lens/installments_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens/installments_test.exs` (inside the module):

```elixir
describe "last_installment_date/1" do
  test "returns start_date + (installments - 1) months" do
    g = %CashLens.Installments.InstallmentGroup{
      start_date: ~D[2025-10-08],
      installments: 10
    }

    assert Installments.last_installment_date(g) == ~D[2026-07-08]
  end

  test "single-installment group ends on its start date" do
    g = %CashLens.Installments.InstallmentGroup{start_date: ~D[2026-01-15], installments: 1}
    assert Installments.last_installment_date(g) == ~D[2026-01-15]
  end

  test "returns nil when start_date is missing" do
    g = %CashLens.Installments.InstallmentGroup{start_date: nil, installments: 3}
    assert Installments.last_installment_date(g) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/installments_test.exs -k last_installment_date`
Expected: FAIL — `function Installments.last_installment_date/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/cash_lens/installments.ex`, add near the existing `add_months/2` definition:

```elixir
@doc """
Returns the date of the final installment for a group:
start_date shifted forward by (installments - 1) months. Nil if no start_date.
"""
def last_installment_date(%{start_date: %Date{} = start_date, installments: n})
    when is_integer(n) and n >= 1 do
  add_months(start_date, n - 1)
end

def last_installment_date(_), do: nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/installments_test.exs -k last_installment_date`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/installments.ex test/cash_lens/installments_test.exs
git commit -m "feat(installments): add last_installment_date/1 helper"
```

---

## Task 2: Context — `list_group_transactions/1`

**Files:**
- Modify: `lib/cash_lens/installments.ex`
- Test: `test/cash_lens/installments_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens/installments_test.exs`:

```elixir
describe "list_group_transactions/1" do
  test "returns the group's transactions ordered by installment_number" do
    {:ok, g} =
      Installments.create_installment_group(%{
        description_pattern: "LOJA Y",
        installments: 3,
        start_date: ~D[2026-01-01]
      })

    acc = account_fixture()

    t2 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 2/3"})
    t1 = transaction_fixture(%{account_id: acc.id, amount: "-10.00", description: "Y 1/3"})

    Repo.update_all(from(t in Transaction, where: t.id == ^t1.id),
      set: [installment_group_id: g.id, installment_number: 1]
    )

    Repo.update_all(from(t in Transaction, where: t.id == ^t2.id),
      set: [installment_group_id: g.id, installment_number: 2]
    )

    numbers =
      g.id
      |> Installments.list_group_transactions()
      |> Enum.map(& &1.installment_number)

    assert numbers == [1, 2]
  end

  test "returns [] for a group with no transactions" do
    {:ok, g} =
      Installments.create_installment_group(%{
        description_pattern: "EMPTY",
        installments: 2,
        start_date: ~D[2026-01-01]
      })

    assert Installments.list_group_transactions(g.id) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens/installments_test.exs -k list_group_transactions`
Expected: FAIL — `function Installments.list_group_transactions/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/cash_lens/installments.ex` (the file already imports `Ecto.Query` and aliases `Transaction` and `Repo` — verify; if not, use fully-qualified names):

```elixir
@doc """
Lists the transactions (parcels) linked to an installment group,
ordered by installment number, then by date.
"""
def list_group_transactions(group_id) do
  from(t in Transaction,
    where: t.installment_group_id == ^group_id,
    order_by: [asc_nulls_last: t.installment_number, asc: t.date]
  )
  |> Repo.all()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens/installments_test.exs -k list_group_transactions`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens/installments.ex test/cash_lens/installments_test.exs
git commit -m "feat(installments): add list_group_transactions/1"
```

---

## Task 3: LiveView — "Última Parcela" column

**Files:**
- Modify: `lib/cash_lens_web/live/installment_live/index.ex`
- Test: `test/cash_lens_web/live/installment_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens_web/live/installment_live_test.exs`:

```elixir
test "shows the last-installment month/year column", %{conn: conn} do
  {:ok, _group} =
    Installments.create_installment_group(%{
      description_pattern: "ULTIMA (10x)",
      total_amount: "1000.00",
      installments: 10,
      start_date: ~D[2025-10-08]
    })

  {:ok, _live, html} = live(conn, ~p"/installments")

  assert html =~ "Última Parcela"
  # 2025-10 + 9 months = 2026-07 -> "jul/26"
  assert html =~ "jul/26"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k "last-installment"`
Expected: FAIL — assertion on "Última Parcela" / "jul/26" not found.

- [ ] **Step 3: Write minimal implementation**

In `lib/cash_lens_web/live/installment_live/index.ex`:

(a) Add a private helper near the other `defp` helpers (after `zebra_by_remaining/1`):

```elixir
defp last_parcel_label(group) do
  case Installments.last_installment_date(group) do
    %Date{} = d ->
      yy = d.year |> Integer.to_string() |> String.slice(-2, 2)
      "#{String.downcase(CashLensWeb.Formatters.month_label(d.month))}/#{yy}"

    _ ->
      "---"
  end
end
```

(Note: `month_label/1` is already imported via `use CashLensWeb, :live_view`; if calling bare `month_label(...)` compiles, prefer that over the fully-qualified call to match existing usage of `month_name/1` in this file.)

(b) In the `<thead>`, add a header after the `Início` column header:

```heex
<th class="text-right">Início</th>
<th class="text-right">Última Parcela</th>
```

(c) In the `<tbody>` group `<tr>`, add a cell after the `Início` cell:

```heex
<td class="text-right text-xs opacity-60 whitespace-nowrap">
  {format_date(group.start_date)}
</td>
<td class="text-right text-xs opacity-60 whitespace-nowrap">
  {last_parcel_label(group)}
</td>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k "last-installment"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens_web/live/installment_live/index.ex test/cash_lens_web/live/installment_live_test.exs
git commit -m "feat(installments-ui): add Última Parcela column"
```

---

## Task 4: LiveView — search filters

**Files:**
- Modify: `lib/cash_lens_web/live/installment_live/index.ex`
- Test: `test/cash_lens_web/live/installment_live_test.exs`

Filters: `name` (contains on description_pattern), `total_amount` (string-contains on the Decimal), `installment_amount` (string-contains on `total_amount / installments`), `start_from` / `start_to` (date range on `start_date`).

- [ ] **Step 1: Write the failing tests**

Add to `test/cash_lens_web/live/installment_live_test.exs`:

```elixir
describe "filters" do
  setup do
    {:ok, a} =
      Installments.create_installment_group(%{
        description_pattern: "ALPHA STORE",
        total_amount: "300.00",
        installments: 3,
        start_date: ~D[2026-01-10]
      })

    {:ok, b} =
      Installments.create_installment_group(%{
        description_pattern: "BETA SHOP",
        total_amount: "1200.00",
        installments: 12,
        start_date: ~D[2026-03-20]
      })

    %{a: a, b: b}
  end

  test "filters by name (case-insensitive substring)", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")
    html = render_change(live, "filter", %{"filters" => %{"name" => "beta"}})

    assert html =~ "BETA SHOP"
    refute html =~ "ALPHA STORE"
  end

  test "filters by total amount", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")
    html = render_change(live, "filter", %{"filters" => %{"total_amount" => "1200"}})

    assert html =~ "BETA SHOP"
    refute html =~ "ALPHA STORE"
  end

  test "filters by installment value (total / installments)", %{conn: conn} do
    # ALPHA: 300/3 = 100 ; BETA: 1200/12 = 100 -> both match "100"
    {:ok, live, _html} = live(conn, ~p"/installments")
    html = render_change(live, "filter", %{"filters" => %{"installment_amount" => "100"}})

    assert html =~ "ALPHA STORE"
    assert html =~ "BETA SHOP"
  end

  test "filters by start date range", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")

    html =
      render_change(live, "filter", %{
        "filters" => %{"start_from" => "2026-03-01", "start_to" => "2026-03-31"}
      })

    assert html =~ "BETA SHOP"
    refute html =~ "ALPHA STORE"
  end

  test "clear_filters restores the full list", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/installments")
    render_change(live, "filter", %{"filters" => %{"name" => "beta"}})

    html = render_click(live, "clear_filters", %{})
    assert html =~ "ALPHA STORE"
    assert html =~ "BETA SHOP"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k filters`
Expected: FAIL — event "filter" not handled / assertions fail.

- [ ] **Step 3: Write minimal implementation**

In `lib/cash_lens_web/live/installment_live/index.ex`:

(a) Update `mount/3` to seed filter assigns BEFORE `load_data/1`:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:show_modal, false)
   |> assign(:filters, default_filters())
   |> assign(:expanded_ids, MapSet.new())
   |> assign(
     :form,
     to_form(Installments.change_installment_group(%Installments.InstallmentGroup{}))
   )
   |> load_data()}
end
```

(b) Replace `load_data/1` to pass filters and compute `filters_active?`:

```elixir
defp load_data(socket) do
  socket
  |> assign(:groups, list_groups(socket.assigns.filters))
  |> assign(:filters_active?, filters_active?(socket.assigns.filters))
  |> assign(:upcoming, Installments.upcoming_installments())
end
```

(c) Replace `list_groups/0` with `list_groups/1`:

```elixir
defp list_groups(filters) do
  Installments.list_installment_groups()
  |> Enum.map(fn g -> Installments.get_group_with_progress(g.id) end)
  |> Enum.reject(& &1.is_finished)
  |> Enum.filter(&matches_filters?(&1, filters))
  # Fewest remaining parcels first (closest to finishing on top).
  |> Enum.sort_by(& &1.remaining_count)
  |> zebra_by_remaining()
end
```

(d) Add filter helpers (near the other `defp`s):

```elixir
defp default_filters do
  %{
    "name" => "",
    "total_amount" => "",
    "installment_amount" => "",
    "start_from" => "",
    "start_to" => ""
  }
end

defp filters_active?(filters), do: Enum.any?(filters, fn {_k, v} -> v not in [nil, ""] end)

defp matches_filters?(group, filters) do
  name_match?(group, filters["name"]) and
    amount_match?(group.total_amount, filters["total_amount"]) and
    amount_match?(installment_value(group), filters["installment_amount"]) and
    start_from_match?(group, filters["start_from"]) and
    start_to_match?(group, filters["start_to"])
end

defp name_match?(_group, blank) when blank in [nil, ""], do: true

defp name_match?(group, needle),
  do: String.contains?(String.downcase(group.description_pattern || ""), String.downcase(needle))

defp amount_match?(_value, blank) when blank in [nil, ""], do: true
defp amount_match?(nil, _needle), do: false

defp amount_match?(%Decimal{} = value, needle),
  do: String.contains?(Decimal.to_string(value), String.trim(needle))

defp installment_value(%{total_amount: %Decimal{} = total, installments: n})
     when is_integer(n) and n > 0,
     do: Decimal.round(Decimal.div(total, n), 2)

defp installment_value(_), do: nil

defp start_from_match?(_group, blank) when blank in [nil, ""], do: true
defp start_from_match?(%{start_date: nil}, _needle), do: false

defp start_from_match?(group, date_str) do
  case Date.from_iso8601(date_str) do
    {:ok, d} -> Date.compare(group.start_date, d) != :lt
    _ -> true
  end
end

defp start_to_match?(_group, blank) when blank in [nil, ""], do: true
defp start_to_match?(%{start_date: nil}, _needle), do: false

defp start_to_match?(group, date_str) do
  case Date.from_iso8601(date_str) do
    {:ok, d} -> Date.compare(group.start_date, d) != :gt
    _ -> true
  end
end
```

(e) Add event handlers (near the other `handle_event/3` clauses — keep them grouped together to satisfy `--warnings-as-errors`):

```elixir
@impl true
def handle_event("filter", %{"filters" => params}, socket) do
  filters = Map.merge(socket.assigns.filters, params)
  {:noreply, socket |> assign(:filters, filters) |> load_data()}
end

@impl true
def handle_event("clear_filters", _params, socket) do
  {:noreply, socket |> assign(:filters, default_filters()) |> load_data()}
end
```

(f) Add the filter bar in `render/1`, immediately above the `<%!-- Lista de grupos de parcelamento --%>` block:

```heex
<%!-- Filtros --%>
<form
  phx-change="filter"
  class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-4 flex flex-wrap items-end gap-3"
>
  <label class="form-control">
    <span class="label-text text-[10px] uppercase opacity-50">Nome</span>
    <input
      type="text"
      name="filters[name]"
      value={@filters["name"]}
      placeholder="Buscar..."
      class="input input-bordered input-sm rounded-xl"
    />
  </label>
  <label class="form-control">
    <span class="label-text text-[10px] uppercase opacity-50">Valor Total</span>
    <input
      type="text"
      name="filters[total_amount]"
      value={@filters["total_amount"]}
      class="input input-bordered input-sm rounded-xl w-28"
    />
  </label>
  <label class="form-control">
    <span class="label-text text-[10px] uppercase opacity-50">Valor da Parcela</span>
    <input
      type="text"
      name="filters[installment_amount]"
      value={@filters["installment_amount"]}
      class="input input-bordered input-sm rounded-xl w-28"
    />
  </label>
  <label class="form-control">
    <span class="label-text text-[10px] uppercase opacity-50">Início (de)</span>
    <input
      type="date"
      name="filters[start_from]"
      value={@filters["start_from"]}
      class="input input-bordered input-sm rounded-xl"
    />
  </label>
  <label class="form-control">
    <span class="label-text text-[10px] uppercase opacity-50">Início (até)</span>
    <input
      type="date"
      name="filters[start_to]"
      value={@filters["start_to"]}
      class="input input-bordered input-sm rounded-xl"
    />
  </label>
  <button
    :if={@filters_active?}
    type="button"
    phx-click="clear_filters"
    class="btn btn-ghost btn-sm rounded-xl"
  >
    <.icon name="hero-x-mark" class="size-4 mr-1" /> Limpar
  </button>
</form>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k filters`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens_web/live/installment_live/index.ex test/cash_lens_web/live/installment_live_test.exs
git commit -m "feat(installments-ui): add search filters (name, amounts, start-date range)"
```

---

## Task 5: LiveView — expandable rows listing parcels

**Files:**
- Modify: `lib/cash_lens_web/live/installment_live/index.ex`
- Test: `test/cash_lens_web/live/installment_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/cash_lens_web/live/installment_live_test.exs`:

```elixir
test "expands a group row to list its parcels", %{conn: conn} do
  {:ok, group} =
    Installments.create_installment_group(%{
      description_pattern: "EXPAND ME",
      total_amount: "200.00",
      installments: 2,
      start_date: ~D[2026-01-05]
    })

  acc = account_fixture()

  tx =
    transaction_fixture(%{
      account_id: acc.id,
      amount: "-100.00",
      description: "EXPAND ME parcela 1"
    })

  Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
    set: [installment_group_id: group.id, installment_number: 1]
  )

  {:ok, live, html} = live(conn, ~p"/installments")
  refute html =~ "EXPAND ME parcela 1"

  html = render_click(live, "toggle_expand", %{"id" => group.id})
  assert html =~ "EXPAND ME parcela 1"

  html = render_click(live, "toggle_expand", %{"id" => group.id})
  refute html =~ "EXPAND ME parcela 1"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k "expands a group"`
Expected: FAIL — event "toggle_expand" not handled / parcel description not rendered.

- [ ] **Step 3: Write minimal implementation**

In `lib/cash_lens_web/live/installment_live/index.ex`:

(a) Add the handler (grouped with the other `handle_event/3` clauses):

```elixir
@impl true
def handle_event("toggle_expand", %{"id" => id}, socket) do
  expanded =
    if MapSet.member?(socket.assigns.expanded_ids, id),
      do: MapSet.delete(socket.assigns.expanded_ids, id),
      else: MapSet.put(socket.assigns.expanded_ids, id)

  {:noreply, assign(socket, :expanded_ids, expanded)}
end
```

(b) Add a private helper to format a parcel's billing month and a status:

```elixir
defp parcel_status(%{date: %Date{} = d}) do
  if Date.compare(d, Date.utc_today()) == :gt, do: "a vencer", else: "paga"
end

defp parcel_status(_), do: "—"
```

(c) Make the group `<tr>` clickable and add a chevron as the FIRST cell. Update the opening `<tr>` and prepend a chevron cell. The group row currently starts:

```heex
<tr
  :for={group <- @groups}
  class={["hover", if(group.band == 0, do: "bg-base-100", else: "bg-base-300")]}
>
  <td class="font-bold text-xs">{group.description_pattern}</td>
```

Change it to make the description cell toggle expansion and show a chevron:

```heex
<tr
  :for={group <- @groups}
  class={["hover", if(group.band == 0, do: "bg-base-100", else: "bg-base-300")]}
>
  <td class="font-bold text-xs">
    <button
      type="button"
      phx-click="toggle_expand"
      phx-value-id={group.id}
      class="flex items-center gap-2 text-left w-full"
    >
      <.icon
        name="hero-chevron-right"
        class={[
          "size-3 transition-transform",
          MapSet.member?(@expanded_ids, group.id) && "rotate-90"
        ]}
      />
      {group.description_pattern}
    </button>
  </td>
```

(Leave the remaining `<td>`s — Valor Total, Parcela, Progresso, Início, Última Parcela, delete — unchanged. The delete button already has its own `phx-click="delete"`; because it is a separate `<button>`, clicking it does not trigger the chevron button.)

(d) Immediately AFTER the group `</tr>` (still inside `<tbody>`, within the `:for`), add the expandable parcels sub-row:

```heex
</tr>
<tr :if={MapSet.member?(@expanded_ids, group.id)} class="bg-base-200/40">
  <td colspan="7" class="p-0">
    <div class="px-6 py-3">
      <% parcels = Installments.list_group_transactions(group.id) %>
      <div :if={parcels == []} class="text-xs opacity-40 py-2">
        Nenhuma parcela importada ainda.
      </div>
      <table :if={parcels != []} class="table table-xs w-full">
        <thead class="text-[9px] uppercase tracking-wider opacity-50">
          <tr>
            <th class="w-12">Parc.</th>
            <th>Descrição</th>
            <th class="text-right">Data</th>
            <th class="text-right">Valor</th>
            <th class="text-right">Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- parcels}>
            <td class="font-mono text-[11px]">{p.installment_number || "—"}</td>
            <td class="text-xs">{p.description}</td>
            <td class="text-right text-xs opacity-60 whitespace-nowrap">{format_date(p.date)}</td>
            <td class="text-right font-mono text-xs">{format_currency(p.amount)}</td>
            <td class="text-right text-[10px] uppercase opacity-60">{parcel_status(p)}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </td>
</tr>
```

(Note: the group table has 7 columns after Task 3 — Descrição, Valor Total, Parcela, Progresso, Início, Última Parcela, action — so `colspan="7"` spans the full width. Verify the count when applying and adjust if it differs.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cash_lens_web/live/installment_live_test.exs -k "expands a group"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cash_lens_web/live/installment_live/index.ex test/cash_lens_web/live/installment_live_test.exs
git commit -m "feat(installments-ui): expandable rows listing parcels"
```

---

## Task 6: Full verification & quality gates

- [ ] **Step 1: Run the whole installments suite**

Run: `mix test test/cash_lens/installments_test.exs test/cash_lens_web/live/installment_live_test.exs`
Expected: all PASS.

- [ ] **Step 2: Run quality gates**

Run:
```bash
mix format
mix credo --strict lib/cash_lens_web/live/installment_live/index.ex lib/cash_lens/installments.ex
mix compile --warnings-as-errors --force
mix test
```
Expected: format clean; credo no issues; compile ok (handle_event/3 clauses grouped); full suite 0 failures.

- [ ] **Step 3: Commit any formatting fixes**

```bash
git add -A
git commit -m "chore(installments-ui): formatting & quality gate fixes" || echo "nothing to commit"
```

---

## Self-Review Notes (author)

- **Spec coverage:** Última Parcela column → Task 3; filters (name, total, installment value, start-date range) → Task 4; expandable parcel rows → Task 5; context helpers → Tasks 1–2. All spec sections covered.
- **Type consistency:** `last_installment_date/1`, `list_group_transactions/1`, `matches_filters?/2`, `installment_value/1`, `parcel_status/1`, `last_parcel_label/1` used consistently. `list_groups/1` replaces `list_groups/0` everywhere (only caller is `load_data/1`).
- **Edge cases:** nil `total_amount` (amount filter returns false; installment value nil), nil `start_date` (date filters return false, last-parcel "---"), empty parcels (empty state), grouped `handle_event/3` clauses for `--warnings-as-errors`.
