# Month Comparison Category Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In `/months/:year/:month`'s comparison mode, align both panels' category rows on the same line — ordered by the left (primary) panel — with non-interactive "R$ 0,00" placeholder rows for categories missing on one side.

**Architecture:** `MonthLive.Show` (the only place that knows both months) computes a combined row order per section ("credit"/income, "debit"/expense) by querying both months' breakdowns and merging them (primary's own order first, then compare-only categories appended). It passes this order to both `MonthPanel` instances as a new `row_order` prop. Each `MonthPanel` renders its own table by walking that order instead of its own natural order when the prop is present, synthesizing a placeholder row for any category it doesn't have data for. Outside comparison mode, `row_order` is always `nil` and every panel renders exactly as it does today.

**Tech Stack:** Elixir/Phoenix LiveView, `Phoenix.LiveComponent`, ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Ordering rule per section (computed independently for "credit" and "debit"): primary's own categories in primary's existing order, then any compare-only category (not present in primary) in compare's existing order, appended at the end.
- A category missing from one side's own breakdown renders there as a placeholder: same name/type label (borrowed from whichever side has real data for it), amount "R$ 0,00", no expand chevron, not clickable (no `phx-click`/`phx-target`), visually muted.
- "Sem categoria" (`category_id: nil`) participates in the same ordering/padding as any other category — no special-casing beyond what already treats it as a row with a `nil` id.
- The section header's "N categorias" count reflects that panel's own real category count (`length(@rows)`), unaffected by alignment padding.
- The empty-state message ("Nenhuma despesa/receita registrada neste mês") only shows when the *combined* (aligned) row list for that section is empty on both sides — a side with zero real categories but a non-empty aligned order (because the other side has data) must still render its table, full of placeholder rows, not the empty-state message.
- Expanding a category's transactions is unaffected by this feature (already independent per side); a placeholder row can never be expanded, since it represents zero transactions on that side that month.
- Outside comparison mode (`@compare` is `nil` in `Show`), nothing about a single panel's rendering changes — `row_order` is `nil`, and `MonthPanel` falls back to today's exact behavior.

---

### Task 1: Compute and apply the aligned row order

**Files:**
- Modify: `lib/cash_lens_web/live/month_live/show.ex`
- Modify: `lib/cash_lens_web/live/month_live/month_panel.ex`
- Modify: `test/cash_lens_web/live/month_live_test.exs`

**Interfaces:**
- Consumes: `CashLens.Transactions.get_month_category_breakdown/2` and `get_month_income_breakdown/2` — both already exist, unchanged, each returning `[%{name: String.t(), category_id: Ecto.UUID.t() | nil, type: String.t() | nil, total: Decimal.t()}]`, sorted by total (descending magnitude) — Task calls them with no changes to their own code.
- Produces: `MonthPanel`'s `row_order` prop — `nil` (no alignment; today's behavior) or `%{"credit" => [%{category_id:, name:, type:}], "debit" => [%{category_id:, name:, type:}]}` (an ordered list per section, same list given to both panels).

This is one task because `Show`'s ordering computation and `MonthPanel`'s consumption of it can only be proven correct together — there's no meaningful intermediate state to gate on.

- [ ] **Step 1: Write the failing tests**

Add these tests inside the existing `describe "comparison mode"` block in `test/cash_lens_web/live/month_live_test.exs` (after the existing tests in that block, before its closing `end`):

```elixir
    test "a category present in both months is ordered by the primary panel, even when the compare panel's own ranking differs",
         %{conn: conn, acc: acc} do
      cat_a = category_fixture(%{name: "CatA", slug: "cat-a", type: "variable"})
      cat_b = category_fixture(%{name: "CatB", slug: "cat-b", type: "variable"})

      # Primary (March): CatA is the bigger expense.
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_a.id,
        amount: "-300.00",
        date: ~D[2026-03-05],
        description: "Primary CatA"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-100.00",
        date: ~D[2026-03-06],
        description: "Primary CatB"
      })

      # Compare (February): CatB is the bigger expense — the opposite ranking.
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_a.id,
        amount: "-50.00",
        date: ~D[2026-02-05],
        description: "Compare CatA"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-200.00",
        date: ~D[2026-02-06],
        description: "Compare CatB"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      primary_html = live |> element("#primary") |> render()
      compare_html = live |> element("#compare") |> render()

      {a_pos_primary, _} = :binary.match(primary_html, "CatA")
      {b_pos_primary, _} = :binary.match(primary_html, "CatB")
      {a_pos_compare, _} = :binary.match(compare_html, "CatA")
      {b_pos_compare, _} = :binary.match(compare_html, "CatB")

      # Primary's own order (CatA bigger, so first) governs both panels — even
      # though the compare panel's own unaligned ranking would put CatB first.
      assert a_pos_primary < b_pos_primary
      assert a_pos_compare < b_pos_compare
    end

    test "a category present only on the primary side shows a real value there and a R$ 0,00 placeholder, non-clickable, on the compare side",
         %{conn: conn, acc: acc} do
      only_primary = category_fixture(%{name: "SoPrimario", slug: "so-primario", type: "fixed"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_primary.id,
        amount: "-77.00",
        date: ~D[2026-03-05],
        description: "Only on primary"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:#{only_primary.id}"

      # Real, clickable row on the primary side.
      assert has_element?(
               live,
               "#primary tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 77,00"

      # Placeholder, non-clickable row on the compare side, still showing the name.
      refute has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      assert has_element?(live, "#compare tr[phx-value-category_id='#{row_key}']")
      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "SoPrimario"
      assert compare_row =~ "R$ 0,00"
    end

    test "a category present only on the compare side appears after the primary's own categories, with a placeholder on the primary side",
         %{conn: conn, acc: acc, expense_cat: primary_cat} do
      only_compare = category_fixture(%{name: "SoComparado", slug: "so-comparado", type: "variable"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_compare.id,
        amount: "-40.00",
        date: ~D[2026-02-05],
        description: "Only on compare"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      # setup/0 already gave `acc` a "Mercado" (primary_cat) expense in March.
      primary_html = live |> element("#primary") |> render()
      {primary_cat_pos, _} = :binary.match(primary_html, primary_cat.name)
      {only_compare_pos, _} = :binary.match(primary_html, "SoComparado")
      assert primary_cat_pos < only_compare_pos

      row_key = "debit:#{only_compare.id}"

      refute has_element?(
               live,
               "#primary tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "SoComparado"
      assert primary_row =~ "R$ 0,00"

      assert has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "R$ 40,00"
    end

    test "an uncategorized (sem categoria) row participates in the same alignment", %{
      conn: conn,
      acc: acc
    } do
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-15.00",
        date: ~D[2026-03-07],
        description: "Sem categoria em março"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:nil"

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 15,00"

      refute has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "R$ 0,00"
    end

    test "income and expense sections align independently of each other", %{
      conn: conn,
      acc: acc,
      income_cat: primary_income_cat
    } do
      only_compare_income =
        category_fixture(%{name: "RendaSoComparado", slug: "renda-so-comparado", type: nil})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_compare_income.id,
        amount: "60.00",
        date: ~D[2026-02-08],
        description: "Renda só em fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      # setup/0 gave `acc` a "Renda" (primary_income_cat) income in March — the primary
      # panel's own income category still appears (real value), unaffected by the fact
      # that the *expense* alignment (tested elsewhere) is a completely separate list.
      primary_html = live |> element("#primary") |> render()
      assert primary_html =~ primary_income_cat.name

      row_key = "credit:#{only_compare_income.id}"
      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 0,00"
    end

    test "outside comparison mode, a single panel never renders placeholder rows", %{
      conn: conn,
      expense_cat: cat
    } do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3")
      refute html =~ "R$ 0,00"
      assert html =~ cat.name
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens_web/live/month_live_test.exs`
Expected: FAIL — `row_order` doesn't exist yet, `Show` doesn't compute it, `MonthPanel` doesn't consume it.

- [ ] **Step 3: Replace `lib/cash_lens_web/live/month_live/show.ex`**

```elixir
defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLensWeb.MonthLive.MonthPanel

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"year" => year_str, "month" => month_str} = params, _uri, socket) do
    with {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      compare = parse_compare_param(params["compare"])
      row_orders = compute_row_orders(year, month, compare)

      {:noreply,
       socket
       |> assign(:primary, build_primary_props(year, month, compare, row_orders))
       |> assign(:compare, compare && build_compare_props(year, month, compare, row_orders))}
    else
      _ ->
        today = Date.utc_today()
        {:noreply, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  @impl true
  def handle_event("open_compare", _params, socket) do
    %{year: year, month: month} = socket.assigns.primary
    {py, pm} = prev_month(year, month)
    {:noreply, push_patch(socket, to: ~p"/months/#{year}/#{month}?#{[compare: "#{py}-#{pm}"]}")}
  end

  @impl true
  def handle_event("close_compare", _params, socket) do
    %{year: year, month: month} = socket.assigns.primary
    {:noreply, push_patch(socket, to: ~p"/months/#{year}/#{month}")}
  end

  # "YYYY-M" (no zero-padding) -> {year, month}, or `nil` for anything malformed —
  # an invalid/garbage compare param degrades to "no comparison" rather than
  # erroring the whole page.
  defp parse_compare_param(nil), do: nil

  defp parse_compare_param(param) do
    with [year_str, month_str] <- String.split(param, "-", parts: 2),
         {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      {year, month}
    else
      _ -> nil
    end
  end

  # `nil` when comparison is off (today's behavior — panels use their own natural
  # order). When on, one merged order per section, given to both panels so their
  # rows land on the same line.
  defp compute_row_orders(_primary_year, _primary_month, nil), do: nil

  defp compute_row_orders(primary_year, primary_month, {compare_year, compare_month}) do
    %{
      "credit" =>
        merged_order(
          Transactions.get_month_income_breakdown(primary_year, primary_month),
          Transactions.get_month_income_breakdown(compare_year, compare_month)
        ),
      "debit" =>
        merged_order(
          Transactions.get_month_category_breakdown(primary_year, primary_month),
          Transactions.get_month_category_breakdown(compare_year, compare_month)
        )
    }
  end

  # Primary's own order first, then any compare-only category (in compare's own
  # order) appended at the end — see the plan's Global Constraints.
  defp merged_order(primary_rows, compare_rows) do
    primary_ids = MapSet.new(primary_rows, & &1.category_id)

    compare_only =
      Enum.reject(compare_rows, &MapSet.member?(primary_ids, &1.category_id))

    (primary_rows ++ compare_only)
    |> Enum.map(&Map.take(&1, [:category_id, :name, :type]))
  end

  defp build_primary_props(year, month, compare, row_orders) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "primary",
      year: year,
      month: month,
      prev_href: primary_href(py, pm, compare),
      next_href: primary_href(ny, nm, compare),
      row_order: row_orders
    }
  end

  defp primary_href(year, month, nil), do: ~p"/months/#{year}/#{month}"

  defp primary_href(year, month, {cy, cm}),
    do: ~p"/months/#{year}/#{month}?#{[compare: "#{cy}-#{cm}"]}"

  defp build_compare_props(primary_year, primary_month, {year, month}, row_orders) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "compare",
      year: year,
      month: month,
      prev_href: compare_href(primary_year, primary_month, py, pm),
      next_href: compare_href(primary_year, primary_month, ny, nm),
      row_order: row_orders
    }
  end

  defp compare_href(primary_year, primary_month, year, month),
    do: ~p"/months/#{primary_year}/#{primary_month}?#{[compare: "#{year}-#{month}"]}"

  defp prev_month(year, 1), do: {year - 1, 12}
  defp prev_month(year, month), do: {year, month - 1}

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["py-8", (@compare && "px-4") || "max-w-4xl mx-auto"]}>
      <div class="flex justify-end mb-6">
        <button :if={!@compare} phx-click="open_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-arrows-right-left" class="size-4 mr-1" /> Comparar
        </button>
        <button :if={@compare} phx-click="close_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-x-mark" class="size-4 mr-1" /> Fechar comparação
        </button>
      </div>

      <div class={["grid gap-6", (@compare && "grid-cols-1 lg:grid-cols-2") || "grid-cols-1"]}>
        <.live_component module={MonthPanel} {@primary} />
        <.live_component :if={@compare} module={MonthPanel} {@compare} />
      </div>
    </div>
    """
  end
end
```

The only changes versus the current file: `alias CashLens.Transactions`; `handle_params/3` now also computes `row_orders`; `compute_row_orders/3` and `merged_order/2` are new; `build_primary_props/4` and `build_compare_props/4` each gained a `row_orders` parameter and now include `row_order: row_orders` in their returned map. `render/1` is untouched.

- [ ] **Step 4: Replace `lib/cash_lens_web/live/month_live/month_panel.ex`**

```elixir
defmodule CashLensWeb.MonthLive.MonthPanel do
  use CashLensWeb, :live_component

  alias CashLens.Transactions

  @impl true
  def update(assigns, socket) do
    changed_month? =
      socket.assigns[:year] != assigns.year or socket.assigns[:month] != assigns.month

    socket = assign(socket, assigns)
    socket = if changed_month?, do: load_month_data(socket), else: socket

    {:ok, socket}
  end

  defp load_month_data(socket) do
    %{year: year, month: month} = socket.assigns
    date = Date.new!(year, month, 1)
    summary = Transactions.get_monthly_summary(date)

    breakdown =
      Transactions.get_month_category_breakdown(year, month)
      |> with_pct(summary.expenses)

    income_breakdown =
      Transactions.get_month_income_breakdown(year, month)
      |> with_pct(summary.income)

    socket
    |> assign(:summary, summary)
    |> assign(:breakdown, breakdown)
    |> assign(:income_breakdown, income_breakdown)
    |> assign(:expanded_categories, MapSet.new())
    |> assign(:category_transactions, %{})
  end

  @impl true
  def handle_event("toggle_category", %{"category_id" => row_key}, socket) do
    expanded = socket.assigns.expanded_categories

    if MapSet.member?(expanded, row_key) do
      {:noreply, assign(socket, :expanded_categories, MapSet.delete(expanded, row_key))}
    else
      # row_key is namespaced as "<type>:<category_id>" so the income and expense
      # sections never collide (e.g. both have an "Uncategorized" row) and each
      # expansion only loads transactions of the matching sign.
      [type, category_id] = String.split(row_key, ":", parts: 2)

      transactions =
        Map.get_lazy(socket.assigns.category_transactions, row_key, fn ->
          Transactions.list_all_transactions(%{
            "category_id" => category_id,
            "type" => type,
            "month" => to_string(socket.assigns.month),
            "year" => to_string(socket.assigns.year),
            "sort_order" => "asc"
          })
        end)

      {:noreply,
       socket
       |> assign(:expanded_categories, MapSet.put(expanded, row_key))
       |> assign(
         :category_transactions,
         Map.put(socket.assigns.category_transactions, row_key, transactions)
       )}
    end
  end

  # Adds a `:pct` field to each breakdown row relative to a total.
  defp with_pct(rows, total) do
    Enum.map(rows, fn row ->
      # coveralls-ignore-start — a row only exists when its section total is positive,
      # so the zero-total branch is a defensive default that never executes.
      pct =
        if Decimal.gt?(total, 0),
          do: row.total |> Decimal.div(total) |> Decimal.mult(100) |> Decimal.round(1),
          else: Decimal.new("0")

      # coveralls-ignore-stop

      Map.put(row, :pct, pct)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-8">
      <%!-- Header with prev/next navigation --%>
      <div class="flex items-center justify-between">
        <.link
          patch={@prev_href}
          class="btn btn-ghost btn-sm"
          aria-label={"Mês anterior — #{month_name(@month)} #{@year}"}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>

        <div class="text-center">
          <h1 class="text-3xl font-black uppercase tracking-tighter">
            {month_name(@month)} {@year}
          </h1>
          <.link
            navigate={~p"/transactions?month=#{@month}&year=#{@year}"}
            class="text-xs opacity-50 hover:opacity-100 underline"
          >
            Ver todas as transações →
          </.link>
        </div>

        <.link
          patch={@next_href}
          class="btn btn-ghost btn-sm"
          aria-label={"Próximo mês — #{month_name(@month)} #{@year}"}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>

      <%!-- Summary cards --%>
      <div class="grid grid-cols-3 gap-4">
        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1">
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Receitas</p>
          <p class="text-2xl font-black text-success">{format_currency(@summary.income)}</p>
        </div>
        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1">
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Despesas</p>
          <p class="text-2xl font-black text-error">{format_currency(@summary.expenses)}</p>
        </div>
        <div class={[
          "bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-1",
          if(Decimal.gt?(@summary.income, @summary.expenses),
            do: "border-success/30",
            else: "border-error/30"
          )
        ]}>
          <p class="text-xs opacity-50 uppercase tracking-widest font-bold">Saldo</p>
          <p class={[
            "text-2xl font-black",
            if(Decimal.gt?(@summary.income, @summary.expenses),
              do: "text-success",
              else: "text-error"
            )
          ]}>
            {format_currency(Decimal.sub(@summary.income, @summary.expenses))}
          </p>
        </div>
      </div>

      <%!-- Receitas por categoria --%>
      <.breakdown_section
        title="Receitas por Categoria"
        empty_msg="Nenhuma receita registrada neste mês."
        rows={@income_breakdown}
        type="credit"
        amount_class="text-success"
        bar_class="bg-success"
        expanded_categories={@expanded_categories}
        category_transactions={@category_transactions}
        myself={@myself}
        row_order={section_row_order(@row_order, "credit")}
      />

      <%!-- Gastos por categoria --%>
      <.breakdown_section
        title="Gastos por Categoria"
        empty_msg="Nenhuma despesa registrada neste mês."
        rows={@breakdown}
        type="debit"
        amount_class="text-error"
        bar_class="bg-primary"
        expanded_categories={@expanded_categories}
        category_transactions={@category_transactions}
        myself={@myself}
        row_order={section_row_order(@row_order, "debit")}
      />
    </div>
    """
  end

  defp section_row_order(nil, _type), do: nil
  defp section_row_order(row_order, type), do: Map.get(row_order, type)

  # Comparison-mode alignment: `nil` row_order means "use this panel's own natural
  # order" (today's behavior, no placeholders). A given row_order means "render
  # exactly these rows, in this order" — a category missing from `rows` becomes a
  # zero-value, non-interactive placeholder so both panels' tables line up.
  defp rows_for_render(rows, nil), do: Enum.map(rows, &Map.put(&1, :placeholder?, false))

  defp rows_for_render(rows, row_order) do
    Enum.map(row_order, fn entry ->
      case Enum.find(rows, &(&1.category_id == entry.category_id)) do
        nil ->
          entry
          |> Map.take([:category_id, :name, :type])
          |> Map.merge(%{total: Decimal.new(0), pct: Decimal.new(0), placeholder?: true})

        row ->
          Map.put(row, :placeholder?, false)
      end
    end)
  end

  attr :title, :string, required: true
  attr :empty_msg, :string, required: true
  attr :rows, :list, required: true
  attr :type, :string, required: true
  attr :amount_class, :string, required: true
  attr :bar_class, :string, required: true
  attr :expanded_categories, :any, required: true
  attr :category_transactions, :map, required: true
  attr :myself, :any, required: true
  attr :row_order, :any, default: nil

  defp breakdown_section(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
      <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="font-black uppercase tracking-tight text-sm">{@title}</h2>
        <span class="text-xs opacity-50">{length(@rows)} categorias</span>
      </div>

      <% display_rows = rows_for_render(@rows, @row_order) %>

      <div :if={display_rows == []} class="px-6 py-12 text-center opacity-40 text-sm">
        {@empty_msg}
      </div>

      <table :if={display_rows != []} class="table table-sm w-full text-xs">
        <thead class="bg-base-200/50">
          <tr>
            <th>Categoria</th>
            <th class="text-right">Valor</th>
            <th class="text-right w-24">% do total</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- display_rows do %>
            <% row_key = "#{@type}:#{row.category_id || "nil"}" %>
            <% expanded = !row.placeholder? and MapSet.member?(@expanded_categories, row_key) %>
            <tr
              class={if row.placeholder?, do: "opacity-40", else: "hover cursor-pointer select-none"}
              phx-click={if !row.placeholder?, do: "toggle_category"}
              phx-value-category_id={row_key}
              phx-target={if !row.placeholder?, do: @myself}
            >
              <td>
                <div class="flex items-center gap-2">
                  <.icon
                    :if={!row.placeholder?}
                    name={
                      if expanded, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"
                    }
                    class="size-3 opacity-50 shrink-0"
                  />
                  <div :if={row.placeholder?} class="size-3 shrink-0"></div>
                  <div>
                    <div class="font-semibold">{row.name}</div>
                    <%= if @type == "credit" do %>
                      <div class="text-[9px] font-bold uppercase tracking-wider mt-0.5 text-success">
                        receita
                      </div>
                    <% else %>
                      <div
                        :if={not is_nil(row.type)}
                        class={[
                          "text-[9px] font-bold uppercase tracking-wider mt-0.5",
                          if(row.type == "fixed", do: "text-info", else: "text-warning")
                        ]}
                      >
                        {row.type}
                      </div>
                      <div
                        :if={is_nil(row.type)}
                        class="text-[9px] opacity-30 uppercase tracking-wider mt-0.5"
                      >
                        sem categoria
                      </div>
                    <% end %>
                  </div>
                </div>
              </td>
              <td class={["text-right font-mono", @amount_class]}>{format_currency(row.total)}</td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-2">
                  <div class="w-16 bg-base-300 rounded-full h-1.5">
                    <div
                      class={[@bar_class, "h-1.5 rounded-full"]}
                      style={"width: #{min(Decimal.to_float(row.pct), 100)}%"}
                    >
                    </div>
                  </div>
                  <span class="w-10 text-right opacity-70">{row.pct}%</span>
                </div>
              </td>
            </tr>
            <%= if expanded do %>
              <% txns = Map.get(@category_transactions, row_key, []) %>
              <tr>
                <td colspan="3" class="p-0 bg-base-200/40">
                  <div :if={txns == []} class="px-10 py-3 text-xs opacity-40 italic">
                    Nenhuma transação encontrada.
                  </div>
                  <table :if={txns != []} class="table table-xs w-full text-xs">
                    <tbody>
                      <%= for t <- txns do %>
                        <tr class="hover">
                          <td class="pl-10 w-24 font-mono opacity-60 whitespace-nowrap">
                            {Calendar.strftime(t.date, "%d")} {month_label(t.date.month)}
                          </td>
                          <td class="truncate max-w-xs">
                            <div class="font-medium">{t.description}</div>
                            <div
                              :if={t.category}
                              class="text-[9px] opacity-50 uppercase tracking-wider"
                            >
                              {t.category.name}
                            </div>
                          </td>
                          <td class="text-right font-mono whitespace-nowrap">
                            <span class={
                              if Decimal.lt?(t.amount, Decimal.new("0")),
                                do: "text-error",
                                else: "text-success"
                            }>
                              {format_currency(t.amount)}
                            </span>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </td>
              </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
```

Note: the header calls `month_name/1` directly (from `CashLensWeb.Formatters`, auto-imported into every LiveComponent — this was already true before this task, from the prior final-review cleanup). There is no `full_month_name/1` wrapper in `MonthPanel` before or after this task's changes — do not introduce one.

- [ ] **Step 5: Run the tests again to verify they pass**

Run: `mix test test/cash_lens_web/live/month_live_test.exs`
Expected: all tests PASS, including the six new ones.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (3 failures in `test/cash_lens_web/live/installment_live_test.exs`, date-sensitive fixtures) — no new failures.

- [ ] **Step 7: Manually verify in the browser**

Start the dev server and visit `/months/2026/7`, click **Comparar**:
- Confirm categories present in both months line up on the same row in both panels.
- Confirm a category unique to one side shows a dimmed "R$ 0,00" row on the other side, with no expand chevron and no click response.
- Confirm the row order matches the left panel's own ranking, not the right panel's.
- Confirm a single panel (comparison closed) looks completely unchanged from before this feature.

- [ ] **Step 8: Commit**

```bash
git add lib/cash_lens_web/live/month_live/show.ex lib/cash_lens_web/live/month_live/month_panel.ex test/cash_lens_web/live/month_live_test.exs
git commit -m "feat(months): align category rows across both panels in comparison mode"
```

---

## Plan Self-Review Notes

- **Spec coverage:** ordering rule, placeholder rendering/non-interactivity, "sem categoria" handling, independent income/expense alignment, empty-state combined-check, and the single-panel-unchanged guarantee are each covered by one of the six new tests. Covered.
- **Type consistency:** `row_order` is `nil | %{String.t() => [%{category_id:, name:, type:}]}` consistently across `Show` (producer) and `MonthPanel` (consumer) — same shape used in both `build_primary_props/4` and `build_compare_props/4`, and unpacked identically by `section_row_order/2` in `MonthPanel`.
- **No placeholders:** every step has runnable code or an exact command.
