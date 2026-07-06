defmodule CashLensWeb.ForecastLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Forecast

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:edit_item, nil) |> assign_projection()}
  end

  defp assign_projection(socket) do
    today = Date.utc_today()

    items =
      Forecast.list_recurring_items()
      |> Enum.sort_by(&Forecast.next_occurrence_date(&1.day_of_month, today), Date)

    projection = Forecast.project()
    income_date = Forecast.next_income_date(projection)
    income_balance = Forecast.balance_on(projection, Date.add(income_date, -1))

    zero_item_id =
      projection.occurrences
      |> Enum.find(&Decimal.negative?(&1.balance_after))
      |> case do
        nil -> nil
        occ -> occ.item.id
      end

    balance_by_item =
      Enum.reduce(projection.occurrences, %{}, fn occ, acc ->
        Map.put_new(acc, occ.item.id, occ.balance_after)
      end)

    # Build monthly chart points for the next 12 months
    monthly_points =
      Enum.map(0..11, fn offset ->
        year_offset = div(today.month - 1 + offset, 12)
        month = rem(today.month - 1 + offset, 12) + 1
        year = today.year + year_offset
        last_day = Date.days_in_month(Date.new!(year, month, 1))
        end_of_month = Date.new!(year, month, last_day)

        %{
          date: Date.to_iso8601(end_of_month),
          balance: Decimal.to_float(Forecast.balance_on(projection, end_of_month))
        }
      end)

    chart_data = Jason.encode!(monthly_points)

    final_date = Date.add(today, 365)
    final_balance = Forecast.balance_on(projection, final_date)

    socket
    |> assign(:today, today)
    |> assign(:items, items)
    |> assign(:projection, projection)
    |> assign(:zero_item_id, zero_item_id)
    |> assign(:balance_by_item, balance_by_item)
    |> assign(:salary_configured, Enum.any?(items, & &1.is_salary))
    |> assign(:income_date, income_date)
    |> assign(:income_balance, income_balance)
    |> assign(:chart_data, chart_data)
    |> assign(:final_balance, final_balance)
  end

  @impl true
  def handle_event("sync_all", _params, socket) do
    Forecast.sync_all()

    {:noreply,
     socket
     |> assign_projection()
     |> put_flash(:success, "Sincronizado com o histórico.")}
  end

  @impl true
  def handle_event("open_edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :edit_item, Forecast.get_recurring_item!(id))}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :edit_item, nil)}
  end

  @impl true
  def handle_event("save_item", params, socket) do
    attrs = %{
      "day_of_month" => params["day_of_month"],
      "amount" => params["amount"],
      "is_salary" => Map.has_key?(params, "is_salary")
    }

    case Forecast.manual_update(socket.assigns.edit_item, attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(:edit_item, nil) |> assign_projection()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Valores inválidos.")}
    end
  end

  @impl true
  def handle_event("resync_item", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.resync_item(item) do
      {:ok, _} ->
        {:noreply, socket |> assign(:edit_item, nil) |> assign_projection()}

      {:error, :insufficient_history} ->
        {:noreply, put_flash(socket, :error, "Histórico insuficiente para ressincronizar.")}
    end
  end

  @impl true
  def handle_event("toggle_salary", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)
    if item.is_salary, do: Forecast.unset_salary(item), else: Forecast.set_as_salary(item)
    {:noreply, assign_projection(socket)}
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)
    {:ok, _} = Forecast.toggle_active(item)
    {:noreply, assign_projection(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-5xl mx-auto">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Previsão de Fluxo de Caixa</h1>
          <p class="text-xs opacity-50 mt-1">
            Projeção das contas não-cartão de crédito com base nos lançamentos fixos configurados.
          </p>
        </div>
      </div>

      <%!-- 1. KPI Cards --%>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <%= if @projection.zero_date do %>
          <div class="card bg-error/5 border border-error/20 shadow-sm p-6 rounded-2xl flex flex-row items-center gap-4">
            <div class="w-12 h-12 rounded-xl bg-error/10 text-error flex items-center justify-center shrink-0">
              <.icon name="hero-exclamation-triangle" class="size-6" />
            </div>
            <div>
              <span class="text-[10px] font-black uppercase opacity-50 tracking-wider">
                Saldo Zera Em
              </span>
              <h3 class="text-2xl font-black text-error leading-none mt-1">
                {format_date(@projection.zero_date)}
              </h3>
              <p class="text-[10px] opacity-60 mt-1">Nos próximos 365 dias</p>
            </div>
          </div>
        <% else %>
          <div class="card bg-success/5 border border-success/20 shadow-sm p-6 rounded-2xl flex flex-row items-center gap-4">
            <div class="w-12 h-12 rounded-xl bg-success/10 text-success flex items-center justify-center shrink-0">
              <.icon name="hero-check-circle" class="size-6" />
            </div>
            <div>
              <span class="text-[10px] font-black uppercase opacity-50 tracking-wider">
                Saldo Previsto (1 ano)
              </span>
              <h3 class="text-2xl font-black text-success leading-none mt-1">
                {format_currency(@final_balance)}
              </h3>
              <p class="text-[10px] opacity-60 mt-1">Sem saldo negativo previsto</p>
            </div>
          </div>
        <% end %>

        <div class="card bg-base-100 border border-base-300 shadow-sm p-6 rounded-2xl flex flex-row items-center gap-4">
          <div class="w-12 h-12 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
            <.icon name="hero-calendar" class="size-6" />
          </div>
          <div>
            <span class="text-[10px] font-black uppercase opacity-50 tracking-wider">
              Até Receber (Dia {@income_date.day})
            </span>
            <h3 class={[
              "text-2xl font-black leading-none mt-1",
              if(Decimal.negative?(@income_balance), do: "text-error", else: "text-primary")
            ]}>
              {format_currency(@income_balance)}
            </h3>
            <p class="text-[10px] opacity-60 mt-1">
              Véspera do recebimento ({format_date(@income_date)})
            </p>
          </div>
        </div>
      </div>

      <%!-- 2. Chart Card --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm p-6 rounded-2xl">
        <div class="flex items-center justify-between mb-4">
          <div>
            <h2 class="text-sm font-black uppercase tracking-tight">Tendência do Fluxo de Caixa</h2>
            <p class="text-[10px] opacity-50">Projeção diária do saldo acumulado</p>
          </div>
        </div>
        <div class="h-64 relative">
          <canvas id="forecastChart" phx-hook="ForecastChart" data-points={@chart_data}></canvas>
        </div>
      </div>

      <%!-- 3. Split Layout --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <%!-- Left/Center: Timeline of Occurrences --%>
        <div class="lg:col-span-2 space-y-4">
          <div class="bg-base-100 border border-base-300 rounded-2xl shadow-sm p-6">
            <h2 class="text-sm font-black uppercase tracking-tight mb-6 flex items-center gap-1.5 border-b border-base-200 pb-3">
              <.icon name="hero-list-bullet" class="size-4 text-primary" /> Cronograma de Lançamentos
            </h2>

            <div class="relative pl-6 border-l-2 border-base-300/60 space-y-8">
              <%= for occ <- @projection.occurrences do %>
                <div class="relative">
                  <!-- Icon indicator -->
                  <div class={[
                    "absolute -left-[31px] top-0.5 w-4 h-4 rounded-full border-2 border-base-100 flex items-center justify-center shadow-sm",
                    if(Decimal.positive?(occ.item.amount), do: "bg-success", else: "bg-error")
                  ]}>
                  </div>

                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <div class="flex items-center gap-1.5 flex-wrap">
                        <span class="text-xs font-bold">{occ.item.label}</span>
                        <span
                          :if={occ.item.is_salary}
                          class="badge badge-success badge-xs text-[8px] font-black uppercase tracking-wider"
                        >
                          Salário
                        </span>
                      </div>
                      <span class="text-[10px] opacity-50 font-mono">{format_date(occ.date)}</span>
                    </div>

                    <div class="text-right">
                      <span class={[
                        "text-xs font-black font-mono",
                        if(Decimal.positive?(occ.item.amount), do: "text-success", else: "text-error")
                      ]}>
                        {if Decimal.positive?(occ.item.amount), do: "+", else: ""}{format_currency(
                          occ.item.amount
                        )}
                      </span>
                      <div class={[
                        "text-[10px] font-mono mt-0.5",
                        if(Decimal.negative?(occ.balance_after),
                          do: "text-error font-black",
                          else: "opacity-60"
                        )
                      ]}>
                        Saldo: {format_currency(occ.balance_after)}
                      </div>
                    </div>
                  </div>
                  
    <!-- Alert negative balance -->
                  <div
                    :if={Decimal.negative?(occ.balance_after)}
                    class="mt-3 bg-error/5 border border-error/20 text-error rounded-xl p-3 flex items-center gap-2 text-[10px] font-bold"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                    <span>
                      O saldo previsto ficará negativo nesta data ({format_currency(occ.balance_after)}).
                    </span>
                  </div>
                </div>
              <% end %>

              <div
                :if={@projection.occurrences == []}
                class="text-center py-10 opacity-50 text-xs italic"
              >
                Nenhum lançamento previsto nos próximos 365 dias.
              </div>
            </div>
          </div>
        </div>

        <%!-- Right: Config Section --%>
        <div class="space-y-4">
          <div class="bg-base-100 border border-base-300 rounded-2xl shadow-sm p-6">
            <div class="flex items-center justify-between mb-4 border-b border-base-200 pb-3">
              <h2 class="text-sm font-black uppercase tracking-tight flex items-center gap-1.5">
                <.icon name="hero-cog-6-tooth" class="size-4 text-primary" /> Contas Fixas
              </h2>
              <span class="badge badge-ghost badge-sm text-[9px] font-bold">
                {length(@items)} configuradas
              </span>
            </div>

            <div class="space-y-3">
              <%= for item <- @items do %>
                <div class={[
                  "p-3 rounded-xl border transition-all flex items-center justify-between gap-4",
                  if(item.active,
                    do: "border-base-300 bg-base-50/50",
                    else: "border-base-200 bg-base-100 opacity-40"
                  )
                ]}>
                  <div class="min-w-0">
                    <div class="flex items-center gap-1 flex-wrap">
                      <span class="text-xs font-bold truncate">{item.label}</span>
                      <span
                        :if={item.manually_edited}
                        class="badge badge-ghost badge-xs text-[8px] font-semibold"
                      >
                        Manual
                      </span>
                    </div>
                    <div class="text-[10px] opacity-60 mt-0.5">
                      Dia {item.day_of_month} ·
                      <span class={
                        if(Decimal.positive?(item.amount),
                          do: "text-success font-bold",
                          else: "text-error font-bold"
                        )
                      }>
                        {format_currency(item.amount)}
                      </span>
                    </div>
                  </div>

                  <div class="flex items-center gap-1 shrink-0">
                    <button
                      phx-click="toggle_active"
                      phx-value-id={item.id}
                      class="btn btn-ghost btn-xs p-1"
                      title={if item.active, do: "Desativar", else: "Ativar"}
                    >
                      <.icon
                        name={if item.active, do: "hero-check-circle", else: "hero-x-circle"}
                        class={["size-5", if(item.active, do: "text-success", else: "text-base-300")]}
                      />
                    </button>

                    <button
                      phx-click="open_edit"
                      phx-value-id={item.id}
                      class="btn btn-ghost btn-xs p-1"
                      title="Editar"
                    >
                      <.icon name="hero-pencil" class="size-4" />
                    </button>
                  </div>
                </div>
              <% end %>

              <div :if={@items == []} class="text-center py-10 opacity-50 text-xs italic">
                Nenhuma conta fixa configurada.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <.modal :if={@edit_item} id="edit-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4">
        <div class="flex items-center gap-3 mb-6">
          <div class="w-10 h-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center">
            <.icon name="hero-pencil" class="size-5" />
          </div>
          <div>
            <h2 class="text-xl font-black uppercase tracking-tight">{@edit_item.label}</h2>
            <p class="text-xs opacity-50">Editar parâmetros da conta fixa</p>
          </div>
        </div>

        <form phx-submit="save_item" class="space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">
                Dia do mês de vencimento
              </span>
            </label>
            <input
              type="number"
              name="day_of_month"
              min="1"
              max="31"
              value={@edit_item.day_of_month}
              class="input input-bordered w-full rounded-2xl bg-base-200 border-none focus:ring-primary"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">Valor da Transação</span>
              <span class="label-text-alt opacity-50 text-[10px]">
                positivo = receita, negativo = despesa
              </span>
            </label>
            <input
              type="number"
              name="amount"
              step="0.01"
              value={@edit_item.amount}
              class="input input-bordered w-full rounded-2xl bg-base-200 border-none focus:ring-primary font-mono font-bold"
              required
            />
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3 p-0 pt-2">
              <input
                type="checkbox"
                name="is_salary"
                checked={@edit_item.is_salary}
                class="checkbox checkbox-primary checkbox-md rounded-lg"
              />
              <span class="label-text text-xs font-semibold opacity-75">
                É a receita de referência (Salário) para o cálculo do "até receber"
              </span>
            </label>
          </div>

          <div class="flex flex-col sm:flex-row gap-3 pt-4">
            <button type="submit" class="btn btn-primary btn-md rounded-2xl font-black flex-1">
              Salvar Alterações
            </button>
            <button
              type="button"
              phx-click="close_modal"
              class="btn btn-ghost btn-md rounded-2xl flex-1"
            >
              Cancelar
            </button>
          </div>
        </form>

        <div class="divider text-xs opacity-40 my-6">ou restabelecer valores originais</div>

        <button
          phx-click="resync_item"
          phx-value-id={@edit_item.id}
          class="btn btn-outline btn-md w-full rounded-2xl font-bold flex items-center justify-center gap-2"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Ressincronizar com Histórico
        </button>
      </div>
    </.modal>
    """
  end
end
