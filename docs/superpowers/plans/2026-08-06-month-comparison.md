# Month Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Comparar" button to `/months/:year/:month` that opens a second, independently-navigable month panel next to the current one.

**Architecture:** Extract the existing single-month UI (header/arrows, summary cards, category breakdown) from `MonthLive.Show` into a new stateful `MonthLive.MonthPanel` LiveComponent. `MonthLive.Show` becomes a thin coordinator: it parses the path (`year`/`month`) and an optional `compare` query param, builds the href/props for one or two panel instances, and renders them in a responsive grid. Each panel owns its own navigation, expanded-category state, and summary/breakdown data — completely isolated from the other panel because they're separate LiveComponent instances.

**Tech Stack:** Elixir/Phoenix LiveView, `Phoenix.LiveComponent`, ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Primary panel URL stays exactly `/months/:year/:month` (existing route, unchanged in `router.ex`).
- Compare state lives in the `compare` query param, formatted `YYYY-M` (no zero-padding), e.g. `?compare=2026-6`.
- Panel navigation uses `<.link patch={...}>`, never `navigate` — patches only trigger `handle_params`, never a full remount.
- Each panel is a `Phoenix.LiveComponent` instance with `phx-target={@myself}` on its own events, so two panels' state (expanded categories, category-transaction cache) can never collide or leak into each other.
- Existing summary/breakdown queries (`CashLens.Transactions.get_monthly_summary/1`, `get_month_category_breakdown/2`, `get_month_income_breakdown/2`, `list_all_transactions/1`) are reused unchanged — no query-layer changes in this plan.
- A single panel keeps today's `max-w-4xl mx-auto` centering; two panels drop that constraint and use the full width in a `grid-cols-1 lg:grid-cols-2` layout (stacked on narrow screens).

---

### Task 1: Extract `MonthLive.MonthPanel` (pure refactor, no new behavior)

**Files:**
- Create: `lib/cash_lens_web/live/month_live/month_panel.ex`
- Modify: `lib/cash_lens_web/live/month_live/show.ex` (replace with a thin coordinator)
- Modify: `test/cash_lens_web/live/month_live_test.exs` (route two tests' clicks through the DOM element instead of `render_click(live, event, payload)`, since `toggle_category` now belongs to the component, not the LiveView)

**Interfaces:**
- Produces: `CashLensWeb.MonthLive.MonthPanel` — a `Phoenix.LiveComponent`. Assigns it requires from its caller: `id` (string), `year` (integer), `month` (integer), `prev_href` (string), `next_href` (string). It computes and owns internally: `summary`, `breakdown`, `income_breakdown`, `expanded_categories`, `category_transactions`.
- Produces: `CashLensWeb.MonthLive.Show.prev_month/2` and `next_month/2` (unchanged signatures: `(integer, integer) -> {integer, integer}`) — Task 2 reuses these to build both panels' hrefs.

This task changes no user-visible behavior at all — it's the same single panel, same URLs, same clicks. It sets up the component boundary Task 2 builds on.

- [ ] **Step 1: Create the `MonthPanel` LiveComponent with the extracted render/state logic**

Create `lib/cash_lens_web/live/month_live/month_panel.ex`:

```elixir
defmodule CashLensWeb.MonthLive.MonthPanel do
  use CashLensWeb, :live_component

  alias CashLens.Transactions

  @month_names ~w(Janeiro Fevereiro Março Abril Maio Junho
                  Julho Agosto Setembro Outubro Novembro Dezembro)

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

  defp full_month_name(month), do: Enum.at(@month_names, month - 1)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-8">
      <%!-- Header with prev/next navigation --%>
      <div class="flex items-center justify-between">
        <.link patch={@prev_href} class="btn btn-ghost btn-sm">
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>

        <div class="text-center">
          <h1 class="text-3xl font-black uppercase tracking-tighter">
            {full_month_name(@month)} {@year}
          </h1>
          <.link
            navigate={~p"/transactions?month=#{@month}&year=#{@year}"}
            class="text-xs opacity-50 hover:opacity-100 underline"
          >
            Ver todas as transações →
          </.link>
        </div>

        <.link patch={@next_href} class="btn btn-ghost btn-sm">
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
      />
    </div>
    """
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

  defp breakdown_section(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
      <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="font-black uppercase tracking-tight text-sm">{@title}</h2>
        <span class="text-xs opacity-50">{length(@rows)} categorias</span>
      </div>

      <div :if={@rows == []} class="px-6 py-12 text-center opacity-40 text-sm">
        {@empty_msg}
      </div>

      <table :if={@rows != []} class="table table-sm w-full text-xs">
        <thead class="bg-base-200/50">
          <tr>
            <th>Categoria</th>
            <th class="text-right">Valor</th>
            <th class="text-right w-24">% do total</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @rows do %>
            <% row_key = "#{@type}:#{row.category_id || "nil"}" %>
            <% expanded = MapSet.member?(@expanded_categories, row_key) %>
            <tr
              class="hover cursor-pointer select-none"
              phx-click="toggle_category"
              phx-value-category_id={row_key}
              phx-target={@myself}
            >
              <td>
                <div class="flex items-center gap-2">
                  <.icon
                    name={
                      if expanded, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"
                    }
                    class="size-3 opacity-50 shrink-0"
                  />
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

Note the only functional additions versus the code being moved: `phx-target={@myself}` on the toggle `<tr>` (routes the click to this component instance, not the LiveView), and `myself={@myself}` threaded through to the `breakdown_section` function component so it can set that attribute.

- [ ] **Step 2: Replace `MonthLive.Show` with a thin coordinator that renders one `MonthPanel`**

Replace the entire contents of `lib/cash_lens_web/live/month_live/show.ex`:

```elixir
defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLensWeb.MonthLive.MonthPanel

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"year" => year_str, "month" => month_str}, _uri, socket) do
    with {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      {:noreply, assign(socket, :primary, build_panel_props("primary", year, month))}
    else
      _ ->
        today = Date.utc_today()
        {:noreply, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  defp build_panel_props(id, year, month) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: id,
      year: year,
      month: month,
      prev_href: ~p"/months/#{py}/#{pm}",
      next_href: ~p"/months/#{ny}/#{nm}"
    }
  end

  def prev_month(year, 1), do: {year - 1, 12}
  def prev_month(year, month), do: {year, month - 1}

  def next_month(year, 12), do: {year + 1, 1}
  def next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-8 max-w-4xl mx-auto">
      <.live_component module={MonthPanel} {@primary} />
    </div>
    """
  end
end
```

`prev_month/2` and `next_month/2` are now public (`def`, not `defp`) because Task 2 calls them from the same module to build the compare panel's props too — they don't need to move, just stop being private.

- [ ] **Step 3: Update the two `toggle_category` tests to click through the DOM instead of calling the event directly**

The event now belongs to `MonthPanel`, not `MonthLive.Show`, so `render_click(live, "toggle_category", ...)` (which sends straight to the root LiveView) no longer reaches it. Route the click through the actual `<tr>` element instead — `Phoenix.LiveViewTest` reads that element's `phx-target` from the rendered HTML and dispatches to the component automatically.

In `test/cash_lens_web/live/month_live_test.exs`, replace:

```elixir
  test "toggle_category expands and collapses a row", %{conn: conn, expense_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    row_key = "debit:#{cat.id}"

    html = render_click(live, "toggle_category", %{"category_id" => row_key})
    assert html =~ "Compra mercado"

    # Toggling again collapses it.
    render_click(live, "toggle_category", %{"category_id" => row_key})
    refute has_element?(live, "[data-row-key='#{row_key}'] .expanded")
  end

  test "toggle_category expands an income row", %{conn: conn, income_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    html = render_click(live, "toggle_category", %{"category_id" => "credit:#{cat.id}"})
    assert html =~ "Salário"
  end
```

with:

```elixir
  test "toggle_category expands and collapses a row", %{conn: conn, expense_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    row_key = "debit:#{cat.id}"
    selector = "tr[phx-value-category_id='#{row_key}']"

    html = live |> element(selector) |> render_click()
    assert html =~ "Compra mercado"

    # Toggling again collapses it.
    live |> element(selector) |> render_click()
    refute has_element?(live, "[data-row-key='#{row_key}'] .expanded")
  end

  test "toggle_category expands an income row", %{conn: conn, income_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    row_key = "credit:#{cat.id}"
    html = live |> element("tr[phx-value-category_id='#{row_key}']") |> render_click()
    assert html =~ "Salário"
  end
```

- [ ] **Step 4: Run the existing MonthLive test suite**

Run: `mix test test/cash_lens_web/live/month_live_test.exs`
Expected: all 8 tests PASS (same behavior as before the refactor — this step proves the extraction didn't change anything user-visible).

- [ ] **Step 5: Run the full test suite to check for anything else touching these modules**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (if any) — no new failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cash_lens_web/live/month_live/month_panel.ex lib/cash_lens_web/live/month_live/show.ex test/cash_lens_web/live/month_live_test.exs
git commit -m "refactor(months): extract MonthPanel LiveComponent from MonthLive.Show"
```

---

### Task 2: Add the Comparar/Fechar comparação toggle and independent per-panel navigation

**Files:**
- Modify: `lib/cash_lens_web/live/month_live/show.ex`
- Modify: `test/cash_lens_web/live/month_live_test.exs`

**Interfaces:**
- Consumes: `CashLensWeb.MonthLive.MonthPanel` (Task 1) — rendered via `<.live_component module={MonthPanel} {props} />`, where `props` is a map with keys `id`, `year`, `month`, `prev_href`, `next_href`.
- Consumes: `CashLensWeb.MonthLive.Show.prev_month/2`, `next_month/2` (Task 1) — reused to compute the compare panel's own adjacent months.

This task is the actual user-facing feature: the button, the second panel, the URL round-trip, and — because a "Comparar" feature that navigates incorrectly isn't really usable — the two different href-building rules (primary panel's arrows must carry the `compare` param along; the compare panel's arrows must only ever change `compare`, never the path) all land together.

- [ ] **Step 1: Write the failing tests for comparison mode**

Add to `test/cash_lens_web/live/month_live_test.exs`, inside the module, after the existing tests:

```elixir
  describe "comparison mode" do
    test "Comparar button opens a second panel defaulted to the previous month", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3")
      refute html =~ "Fechar comparação"

      html = live |> element("button", "Comparar") |> render_click()

      assert html =~ "Fechar comparação"
      assert html =~ "Fevereiro"
      assert_patch(live, ~p"/months/2026/3?compare=2026-2")
    end

    test "Fechar comparação closes the second panel and clears the URL param", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare=2026-2")
      assert html =~ "Fechar comparação"

      html = live |> element("button", "Fechar comparação") |> render_click()

      refute html =~ "Fechar comparação"
      assert_patch(live, ~p"/months/2026/3")
    end

    test "loading a URL with ?compare= directly renders both panels", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare=2026-1")
      assert html =~ "Março"
      assert html =~ "Janeiro"
    end

    test "the primary panel's arrows preserve the compare param", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-1")

      live |> element("#primary a[href*='/months/2026/4']") |> render_click()

      assert_patch(live, ~p"/months/2026/4?compare=2026-1")
    end

    test "the compare panel's arrows only change the compare param", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-1")

      live |> element("#compare a[href*='compare=2026-2']") |> render_click()

      assert_patch(live, ~p"/months/2026/3?compare=2026-2")
    end

    test "expanding a category in one panel does not expand it in the other", %{
      conn: conn,
      acc: acc,
      expense_cat: cat
    } do
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat.id,
        amount: "-40.00",
        date: ~D[2026-02-05],
        description: "Compra fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:#{cat.id}"
      live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render_click()

      compare_html = live |> element("#compare") |> render()
      primary_html = live |> element("#primary") |> render()

      assert compare_html =~ "Compra fevereiro"
      refute primary_html =~ "Compra fevereiro"
    end

    test "an invalid compare param is ignored rather than erroring the page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare=garbage")
      assert html =~ "Março"
      refute html =~ "Fechar comparação"
    end
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/cash_lens_web/live/month_live_test.exs`
Expected: FAIL — no "Comparar" button exists yet, `assigns.compare` is undefined, etc.

- [ ] **Step 3: Implement compare-mode parsing, the toggle events, and both panels' href-building in `MonthLive.Show`**

Replace `lib/cash_lens_web/live/month_live/show.ex` with:

```elixir
defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

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

      {:noreply,
       socket
       |> assign(:primary, build_primary_props(year, month, compare))
       |> assign(:compare, compare && build_compare_props(year, month, compare))}
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
    {:noreply, push_patch(socket, to: ~p"/months/#{year}/#{month}?compare=#{py}-#{pm}")}
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

  defp build_primary_props(year, month, compare) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "primary",
      year: year,
      month: month,
      prev_href: primary_href(py, pm, compare),
      next_href: primary_href(ny, nm, compare)
    }
  end

  defp primary_href(year, month, nil), do: ~p"/months/#{year}/#{month}"

  defp primary_href(year, month, {cy, cm}),
    do: ~p"/months/#{year}/#{month}?compare=#{cy}-#{cm}"

  defp build_compare_props(primary_year, primary_month, {year, month}) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "compare",
      year: year,
      month: month,
      prev_href: compare_href(primary_year, primary_month, py, pm),
      next_href: compare_href(primary_year, primary_month, ny, nm)
    }
  end

  defp compare_href(primary_year, primary_month, year, month),
    do: ~p"/months/#{primary_year}/#{primary_month}?compare=#{year}-#{month}"

  def prev_month(year, 1), do: {year - 1, 12}
  def prev_month(year, month), do: {year, month - 1}

  def next_month(year, 12), do: {year + 1, 1}
  def next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["py-8", @compare && "px-4" || "max-w-4xl mx-auto"]}>
      <div class="flex justify-end mb-6">
        <button :if={!@compare} phx-click="open_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-arrows-right-left" class="size-4 mr-1" /> Comparar
        </button>
        <button :if={@compare} phx-click="close_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-x-mark" class="size-4 mr-1" /> Fechar comparação
        </button>
      </div>

      <div class={["grid gap-6", @compare && "grid-cols-1 lg:grid-cols-2" || "grid-cols-1"]}>
        <.live_component module={MonthPanel} {@primary} />
        <.live_component :if={@compare} module={MonthPanel} {@compare} />
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run the tests again to verify they pass**

Run: `mix test test/cash_lens_web/live/month_live_test.exs`
Expected: all tests PASS, including the new `comparison mode` describe block.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, with the same pre-existing, unrelated failures as before this change (if any) — no new failures.

- [ ] **Step 6: Manually verify in the browser**

Start the dev server (`mix phx.server` or the project's existing launch config) and visit `/months/2026/7`:
- Click **Comparar** — a second panel appears on the right showing June 2026, and the URL gains `?compare=2026-6`.
- Use the right panel's own ‹ › arrows — only that panel's month changes; the left panel and the page path stay put, only `?compare=` changes.
- Use the left panel's ‹ › arrows — the path changes (e.g. to `/months/2026/8`) and `?compare=2026-6` is preserved in the URL.
- Expand a category in one panel — confirm the other panel's categories stay collapsed.
- Click **Fechar comparação** — back to one panel, `?compare=` gone from the URL.
- Resize the window narrow — panels stack vertically instead of side by side.

- [ ] **Step 7: Commit**

```bash
git add lib/cash_lens_web/live/month_live/show.ex test/cash_lens_web/live/month_live_test.exs
git commit -m "feat(months): add side-by-side month comparison"
```

---

## Plan Self-Review Notes

- **Spec coverage:** LiveComponent extraction (Task 1) → Comparar/Fechar toggle, URL scheme, independent navigation, layout, category isolation (Task 2). All six spec testing bullets have a corresponding test above. Covered.
- **Type consistency:** `build_panel_props/3` (Task 1) is fully replaced by `build_primary_props/3` + `build_compare_props/3` in Task 2's rewrite of `show.ex` — Task 2's Step 3 gives the complete file contents, so there's no leftover reference to the old function name.
- **No placeholders:** every step has runnable code or an exact command.
