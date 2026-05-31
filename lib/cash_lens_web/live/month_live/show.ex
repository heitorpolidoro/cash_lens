defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Transactions

  @month_names ~w(Janeiro Fevereiro Março Abril Maio Junho
                  Julho Agosto Setembro Outubro Novembro Dezembro)

  @impl true
  def mount(%{"year" => year_str, "month" => month_str}, _session, socket) do
    with {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, date} <- Date.new(year, month, 1) do
      summary = Transactions.get_monthly_summary(date)
      breakdown = Transactions.get_month_category_breakdown(year, month)
      total_expenses = summary.expenses

      breakdown_with_pct =
        Enum.map(breakdown, fn row ->
          pct =
            if Decimal.gt?(total_expenses, 0),
              do:
                row.total |> Decimal.div(total_expenses) |> Decimal.mult(100) |> Decimal.round(1),
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
       |> assign(:next, next)
       |> assign(:expanded_categories, MapSet.new())
       |> assign(:category_transactions, %{})}
    else
      _ ->
        today = Date.utc_today()
        {:ok, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  @impl true
  def handle_event("toggle_category", %{"category_id" => row_key}, socket) do
    expanded = socket.assigns.expanded_categories

    if MapSet.member?(expanded, row_key) do
      {:noreply,
       socket
       |> assign(:expanded_categories, MapSet.delete(expanded, row_key))}
    else
      transactions =
        Map.get_lazy(socket.assigns.category_transactions, row_key, fn ->
          Transactions.list_all_transactions(%{
            "category_id" => row_key,
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
            Ver todas as transações →
          </.link>
        </div>

        <.link navigate={~p"/months/#{elem(@next, 0)}/#{elem(@next, 1)}"} class="btn btn-ghost btn-sm">
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

      <%!-- Category breakdown --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-black uppercase tracking-tight text-sm">Gastos por Categoria</h2>
          <span class="text-xs opacity-50">{length(@breakdown)} categorias</span>
        </div>

        <div :if={@breakdown == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma despesa registrada neste mês.
        </div>

        <table :if={@breakdown != []} class="table table-sm w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Categoria</th>
              <th class="text-right">Valor</th>
              <th class="text-right w-24">% do total</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @breakdown do %>
              <% row_key = row.category_id || "nil" %>
              <% expanded = MapSet.member?(@expanded_categories, row_key) %>
              <tr
                class="hover cursor-pointer select-none"
                phx-click="toggle_category"
                phx-value-category_id={row_key}
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
                    </div>
                  </div>
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
                              {Calendar.strftime(t.date, "%b %d")}
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
    </div>
    """
  end
end
