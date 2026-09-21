defmodule CashLensWeb.ForecastLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Forecast

  @ruler_days 90
  @minimum_days 30
  @horizon_days 365

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:modal_mode, nil)
     |> assign(:edit_item, nil)
     |> assign(:form_params, %{})
     |> assign(:form_error, nil)
     |> assign_projection()}
  end

  # The ruler (90 days), the minimum KPI (30 days) and the 12-month KPI are three
  # date slices of ONE projection. The windows are deliberately different: 30 days
  # is the short-term risk gauge, 90 days is the forward visibility of the ruler.
  defp assign_projection(socket) do
    today = Date.utc_today()

    items =
      Forecast.list_recurring_items()
      |> Enum.sort_by(&Forecast.next_occurrence_date(&1.day_of_month, today), Date)

    projection = Forecast.project(@horizon_days)
    income_date = Forecast.next_income_date(projection)
    income_balance = Forecast.balance_on(projection, Date.add(income_date, -1))
    ruler_occurrences = Forecast.occurrences_within(projection, @ruler_days)

    socket
    |> assign(:today, today)
    |> assign(:items, items)
    |> assign(:projection, projection)
    |> assign(:ruler_occurrences, ruler_occurrences)
    |> assign(:critical_date, critical_date(ruler_occurrences))
    |> assign(:minimum_point, Forecast.minimum_point(projection, @minimum_days))
    |> assign(:income_date, income_date)
    |> assign(:income_balance, income_balance)
    |> assign(:final_balance, Forecast.final_balance(projection))
    |> assign(:change_percent, Forecast.projected_change_percent(projection))
    |> assign(:candidate_categories, Forecast.list_categories_without_recurring_item())
  end

  defp critical_date([]), do: nil

  defp critical_date(occurrences) do
    occurrences
    |> Enum.min_by(& &1.balance_after, &(Decimal.compare(&1, &2) != :gt))
    |> Map.fetch!(:date)
  end

  @impl true
  def handle_event("sync_all", _params, socket) do
    Forecast.sync_all()
    {:noreply, assign_projection(socket)}
  end

  @impl true
  def handle_event("open_edit", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    {:noreply,
     socket
     |> assign(:modal_mode, :edit)
     |> assign(:edit_item, item)
     |> assign(:form_error, nil)
     |> assign(:form_params, %{
       "label" => item.label,
       "day_of_month" => to_string(item.day_of_month),
       "amount" => Decimal.to_string(item.amount)
     })}
  end

  @impl true
  def handle_event("open_new", _params, socket) do
    case socket.assigns.candidate_categories do
      [] ->
        {:noreply, socket}

      [first | _rest] ->
        {:noreply,
         socket
         |> assign(:modal_mode, :new)
         |> assign(:edit_item, nil)
         |> assign(:form_error, nil)
         |> assign(:form_params, %{
           "category_id" => first.id,
           "label" => first.name,
           "day_of_month" => "",
           "amount" => ""
         })}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  @impl true
  def handle_event("form_changed", params, socket) do
    {:noreply, assign(socket, :form_params, merge_form_params(socket, params))}
  end

  @impl true
  def handle_event("save_item", params, socket) do
    socket
    |> assign(:form_params, merge_form_params(socket, params))
    |> persist_item(socket.assigns.edit_item, params)
  end

  @impl true
  def handle_event("resync_item", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.resync_item(item) do
      {:ok, _} ->
        {:noreply, socket |> close_modal() |> assign_projection()}

      {:error, :insufficient_history} ->
        {:noreply, assign(socket, :form_error, "Histórico insuficiente para ressincronizar.")}
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

  # An existing item goes through manual_update/2, which already forces
  # manually_edited. A new one must carry the same flag, or the next press of this
  # screen's own "Sincronizar Histórico" would overwrite the typed values.
  defp persist_item(socket, nil, params) do
    attrs = %{
      "category_id" => params["category_id"],
      "label" => params["label"],
      "day_of_month" => params["day_of_month"],
      "amount" => params["amount"],
      "manually_edited" => true
    }

    case Forecast.create_recurring_item(attrs) do
      {:ok, _item} -> {:noreply, socket |> close_modal() |> assign_projection()}
      {:error, _changeset} -> {:noreply, assign(socket, :form_error, "Valores inválidos.")}
    end
  end

  defp persist_item(socket, item, params) do
    attrs = %{
      "day_of_month" => params["day_of_month"],
      "amount" => params["amount"],
      "is_salary" => Map.has_key?(params, "is_salary")
    }

    case Forecast.manual_update(item, attrs) do
      {:ok, _} -> {:noreply, socket |> close_modal() |> assign_projection()}
      {:error, _changeset} -> {:noreply, assign(socket, :form_error, "Valores inválidos.")}
    end
  end

  defp close_modal(socket) do
    socket
    |> assign(:modal_mode, nil)
    |> assign(:edit_item, nil)
    |> assign(:form_error, nil)
    |> assign(:form_params, %{})
  end

  # Picking another category re-fills the label with its name; typing in any other
  # field leaves the label alone.
  defp merge_form_params(socket, params) do
    previous = socket.assigns.form_params
    merged = Map.merge(previous, Map.take(params, ~w(category_id label day_of_month amount)))

    if (socket.assigns.modal_mode == :new and params["category_id"]) &&
         params["category_id"] != previous["category_id"] do
      Map.put(merged, "label", category_name(socket, params["category_id"]))
    else
      merged
    end
  end

  defp category_name(socket, category_id) do
    socket.assigns.candidate_categories
    |> Enum.find(&(&1.id == category_id))
    |> case do
      # coveralls-ignore-next-line — defensive: the select only offers candidate categories.
      nil -> ""
      category -> category.name
    end
  end

  defp field(assigns_params, key), do: Map.get(assigns_params, key, "")

  defp signed_amount(amount) do
    if Decimal.positive?(amount) do
      "+ #{format_currency(amount)}"
    else
      format_currency(amount)
    end
  end

  defp amount_class(amount) do
    if Decimal.positive?(amount), do: "text-success", else: "text-error"
  end

  defp ruler_date(%Date{} = date, today) do
    label = "#{String.pad_leading(to_string(date.day), 2, "0")} #{month_abbrev(date.month)}"

    case Date.diff(date, today) do
      0 -> "#{label} (Hoje)"
      1 -> "#{label} (Amanhã)"
      _ -> label
    end
  end

  defp month_abbrev(month), do: month |> month_label() |> String.capitalize()

  defp end_month(%Date{} = date), do: Calendar.strftime(date, "%m/%Y")

  defp percent_label(percent) do
    if Decimal.negative?(percent) do
      "#{Decimal.to_string(percent)}%"
    else
      "+#{Decimal.to_string(percent)}%"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-7xl mx-auto">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 pb-2 border-b border-base-300">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">
            Previsão de Fluxo de Caixa & Liquidez
          </h1>
          <p class="text-xs opacity-50 mt-1">
            Projeção do saldo disponível em contas correntes com base nos lançamentos recorrentes cadastrados.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-xs opacity-60 font-medium">Saldo Atual em Contas:</span>
          <strong class="text-base font-black">
            {format_currency(@projection.starting_balance)}
          </strong>
        </div>
      </div>

      <%!-- Sync action + always-visible explanation of what it does and does not do --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl p-4 flex flex-col md:flex-row md:items-start gap-4">
        <button
          phx-click="sync_all"
          class="btn btn-sm btn-outline rounded-xl font-bold shrink-0 gap-1.5"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Sincronizar Histórico
        </button>
        <div class="text-xs opacity-70 leading-relaxed" data-role="sync-explanation">
          <p class="font-bold opacity-100">
            Sincronização manual — só acontece quando você clica aqui.
          </p>
          <p class="mt-1">
            Percorre apenas categorias marcadas como <strong>Fixo (Contas Essenciais)</strong>
            — cartões de crédito ficam de fora — e precisa de pelo menos
            <strong>2 lançamentos nos últimos 180 dias</strong>
            em contas que não sejam cartão. O dia vem da <strong>mediana</strong>
            dos lançamentos; o valor vem do <strong>lançamento mais recente</strong>.
            Esta sincronização não altera itens editados à mão; para atualizar um deles, use
            <strong>Ressincronizar com Histórico</strong>
            no próprio item. Nenhuma recorrência é descoberta sozinha: marcar a categoria como Fixo é o que a torna elegível.
          </p>
        </div>
      </div>

      <%!-- Three projection KPIs. No record count is displayed on this screen. --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div
          class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl p-5"
          data-role="kpi-pre-salary"
        >
          <span class="text-[11px] font-black uppercase tracking-wider opacity-50">
            Saldo Pré-Salário
          </span>
          <div class="flex items-baseline justify-between mt-1">
            <span class={[
              "text-2xl font-black",
              if(Decimal.negative?(@income_balance), do: "text-error", else: "text-primary")
            ]}>
              {format_currency(@income_balance)}
            </span>
          </div>
          <span class="text-[11px] opacity-60 font-medium mt-1 block">
            Projetado para {format_date(Date.add(@income_date, -1))}, véspera do salário ({format_date(
              @income_date
            )})
          </span>
        </div>

        <div
          class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl p-5"
          data-role="kpi-minimum"
        >
          <span class="text-[11px] font-black uppercase tracking-wider opacity-50">
            Mínimo Projetado (30d)
          </span>
          <div class="flex items-baseline justify-between mt-1">
            <span class={[
              "text-2xl font-black",
              if(Decimal.negative?(minimum_balance(@minimum_point, @projection)),
                do: "text-error",
                else: "text-success"
              )
            ]}>
              {format_currency(minimum_balance(@minimum_point, @projection))}
            </span>
            <span class={[
              "badge badge-sm text-[10px] font-black",
              if(Decimal.negative?(minimum_balance(@minimum_point, @projection)),
                do: "badge-error",
                else: "badge-success"
              )
            ]}>
              {if Decimal.negative?(minimum_balance(@minimum_point, @projection)),
                do: "Em risco",
                else: "Seguro"}
            </span>
          </div>
          <span class="text-[11px] opacity-60 font-medium mt-1 block">
            {if @minimum_point,
              do: "Vale em #{format_date(@minimum_point.date)}",
              else: "Sem lançamentos previstos nos próximos 30 dias"}
          </span>
        </div>

        <div
          class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl p-5"
          data-role="kpi-twelve-months"
        >
          <span class="text-[11px] font-black uppercase tracking-wider opacity-50">
            Projeção em 12 Meses
          </span>
          <div class="flex items-baseline justify-between mt-1">
            <span class="text-2xl font-black">{format_currency(@final_balance)}</span>
            <span
              :if={@change_percent}
              class={[
                "text-xs font-bold",
                if(Decimal.negative?(@change_percent), do: "text-error", else: "text-success")
              ]}
            >
              {percent_label(@change_percent)}
            </span>
          </div>
          <span class="text-[11px] opacity-60 font-medium mt-1 block">
            Saldo projetado ao fim de 12 meses
          </span>
        </div>
      </div>

      <%!-- Liquidity ruler: one single horizontally scrollable row --%>
      <div
        class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl p-6 space-y-4 overflow-hidden"
        data-role="ruler"
      >
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <div>
            <h2 class="text-xs font-black uppercase tracking-wider">
              Régua Temporal de Liquidez (Próximos 90 Dias)
            </h2>
            <p class="text-xs opacity-50">
              Acompanhe dia a dia o impacto dos vencimentos recorrentes, das faturas de cartão e das recorrências temporárias no saldo em conta. Role para o lado para ver mais adiante.
            </p>
            <p class="text-[11px] opacity-50 mt-1">
              <strong>Recorrência temporária</strong>: financiamento ou consórcio pago fora do cartão — tem fim conhecido e mostra a posição da parcela. Parcelas de cartão não aparecem aqui: elas já estão dentro da fatura.
            </p>
          </div>
          <span class="text-xs font-semibold opacity-50">Ordenado por data de liquidação</span>
        </div>

        <div class="relative pt-2 pb-2 min-w-0">
          <div
            class="flex flex-nowrap items-stretch gap-3 overflow-x-auto pb-3"
            data-role="ruler-strip"
          >
            <div
              :for={occ <- @ruler_occurrences}
              data-role="ruler-event"
              class={[
                "w-[198px] shrink-0 rounded-2xl border p-3 space-y-2",
                ruler_card_class(occ, @critical_date)
              ]}
            >
              <%!-- 1. date --%>
              <div class="flex items-center justify-between">
                <span class="text-xs font-black">{ruler_date(occ.date, @today)}</span>
                <span class={[
                  "w-2.5 h-2.5 rounded-full",
                  if(Decimal.positive?(occ.item.amount), do: "bg-success", else: "bg-error")
                ]}>
                </span>
              </div>

              <div class="space-y-0.5">
                <%!-- 2. reason, carrying the variant marker --%>
                <div class="flex items-center gap-1.5">
                  <.icon
                    :if={Map.get(occ, :origin)}
                    name="hero-credit-card"
                    class="size-3.5 text-secondary shrink-0"
                  />
                  <.icon
                    :if={Map.get(occ, :commitment)}
                    name="hero-clock"
                    class="size-3.5 text-info shrink-0"
                  />
                  <span class="text-xs font-bold truncate" title={occ.item.label}>
                    {occ.item.label}
                  </span>
                </div>
                <span
                  :if={Map.get(occ, :origin)}
                  class="badge badge-sm badge-secondary text-[10px] font-black"
                >
                  Fatura de cartão
                </span>
                <span
                  :if={Map.get(occ, :commitment)}
                  class="badge badge-sm badge-info text-[10px] font-black"
                >
                  Recorrência temporária
                </span>
                <span
                  :if={occ.item.is_salary}
                  class="badge badge-sm badge-success text-[10px] font-black"
                >
                  Salário
                </span>

                <%!-- 3. the event's own amount --%>
                <span
                  data-role="ruler-amount"
                  class={["block text-xs font-bold font-mono", amount_class(occ.item.amount)]}
                >
                  {signed_amount(occ.item.amount)}
                </span>

                <%!-- Installment disclosure, right under the amount it qualifies --%>
                <.installment_disclosure
                  :if={disclose_installments?(occ)}
                  total={occ.installment_total}
                  groups={occ.installment_groups}
                />

                <.commitment_detail :if={Map.get(occ, :commitment)} commitment={occ.commitment} />

                <span
                  :if={occ.date == @critical_date}
                  class="badge badge-sm badge-warning text-[10px] font-black"
                >
                  Ponto crítico
                </span>
              </div>

              <%!-- 4. and 5. the "Saldo após" label and the dominant running balance --%>
              <div class="pt-2 border-t border-base-300/60">
                <span class="block text-[10px] font-bold uppercase tracking-wider opacity-50">
                  Saldo após
                </span>
                <strong
                  data-role="ruler-balance"
                  class="block text-lg font-black leading-tight font-mono"
                >
                  {format_currency(occ.balance_after)}
                </strong>
              </div>
            </div>

            <div :if={@ruler_occurrences == []} class="py-8 opacity-50 text-xs italic">
              Nenhum lançamento previsto nos próximos 90 dias.
            </div>
          </div>
        </div>
      </div>

      <%!-- Registered recurring items. No count is rendered next to the heading. --%>
      <div class="space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <h2 class="text-xs font-black uppercase tracking-wider" data-role="items-heading">
            Lançamentos Recorrentes Cadastrados
          </h2>
          <div class="flex items-center gap-3 flex-wrap">
            <span :if={@candidate_categories == []} class="text-xs opacity-60">
              Todas as categorias já possuem um lançamento recorrente
            </span>
            <span :if={@candidate_categories != []} class="text-xs opacity-60">
              Detectados a partir do histórico ou criados manualmente.
            </span>
            <button
              phx-click="open_new"
              disabled={@candidate_categories == []}
              class="btn btn-sm btn-primary rounded-xl font-bold gap-1.5"
            >
              <.icon name="hero-plus" class="size-4" /> Novo Item Recorrente
            </button>
          </div>
        </div>

        <div
          class="bg-base-100 border border-base-300 rounded-2xl shadow-sm overflow-hidden divide-y divide-base-200"
          data-role="items-list"
        >
          <div
            :for={item <- @items}
            data-role="recurring-item"
            class={[
              "p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4",
              !item.active && "opacity-40"
            ]}
          >
            <div class="flex items-center gap-4">
              <div class={[
                "w-10 h-10 rounded-xl font-black text-xs flex flex-col items-center justify-center leading-none",
                if(Decimal.positive?(item.amount),
                  do: "bg-success/10 text-success",
                  else: "bg-error/10 text-error"
                )
              ]}>
                <span class="text-[9px] uppercase font-bold opacity-75">Dia</span>
                <span class="text-sm font-extrabold">{item.day_of_month}</span>
              </div>
              <div>
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="text-sm font-bold">{item.label}</span>
                  <span
                    :if={item.is_salary}
                    class="badge badge-sm badge-success text-[10px] font-black"
                  >
                    Salário Principal
                  </span>
                  <span :if={item.manually_edited} class="badge badge-sm badge-ghost text-[10px]">
                    Manual
                  </span>
                </div>
                <span class="text-xs opacity-50">
                  {if item.active, do: "Ativo", else: "Inativo"}
                </span>
              </div>
            </div>

            <div class="flex items-center gap-4 self-end sm:self-center">
              <span class={["text-sm font-black font-mono", amount_class(item.amount)]}>
                {signed_amount(item.amount)}
              </span>
              <div class="flex items-center gap-1">
                <button
                  phx-click="toggle_salary"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs p-1"
                  aria-label="Marcar como salário principal"
                >
                  <.icon
                    name="hero-banknotes"
                    class={["size-4", if(item.is_salary, do: "text-success", else: "opacity-40")]}
                  />
                </button>
                <button
                  phx-click="open_edit"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs p-1"
                  aria-label="Editar"
                >
                  <.icon name="hero-pencil" class="size-4" />
                </button>
                <button
                  phx-click="toggle_active"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs p-1"
                  aria-label={if item.active, do: "Desativar", else: "Ativar"}
                >
                  <.icon
                    name={if item.active, do: "hero-check-circle", else: "hero-x-circle"}
                    class={["size-5", if(item.active, do: "text-success", else: "opacity-40")]}
                  />
                </button>
              </div>
            </div>
          </div>

          <div :if={@items == []} class="text-center py-10 opacity-50 text-xs italic">
            Nenhum lançamento recorrente cadastrado.
          </div>
        </div>
      </div>
    </div>

    <.modal :if={@modal_mode} id="item-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <div class="mb-6">
          <h2 class="text-xl font-black uppercase tracking-tight">
            {if @modal_mode == :new, do: "Novo Item Recorrente", else: @edit_item.label}
          </h2>
          <p class="text-xs opacity-50 mt-0.5">
            {if @modal_mode == :new,
              do:
                "Informe a categoria, o dia habitual e o valor. O item fica fora da sincronização com o histórico.",
              else: "Ajuste o valor estimado e o dia habitual de liquidação."}
          </p>
        </div>

        <p :if={@form_error} class="alert alert-error text-xs font-bold mb-4">{@form_error}</p>

        <form phx-submit="save_item" phx-change="form_changed" class="space-y-4">
          <div :if={@modal_mode == :new} class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">Categoria</span>
            </label>
            <select
              name="category_id"
              class="select select-bordered w-full rounded-2xl bg-base-200 border-none"
            >
              <option
                :for={category <- @candidate_categories}
                value={category.id}
                selected={category.id == field(@form_params, "category_id")}
              >
                {category.name}
              </option>
            </select>
            <span class="text-[11px] opacity-50 mt-1">
              Cada categoria admite um único lançamento recorrente.
            </span>
          </div>

          <div :if={@modal_mode == :new} class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">Descrição</span>
            </label>
            <input
              type="text"
              name="label"
              value={field(@form_params, "label")}
              class="input input-bordered w-full rounded-2xl bg-base-200 border-none"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">Dia do Mês (1-31)</span>
            </label>
            <input
              type="number"
              name="day_of_month"
              min="1"
              max="31"
              value={field(@form_params, "day_of_month")}
              class="input input-bordered w-full rounded-2xl bg-base-200 border-none"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold text-xs opacity-75">Valor Médio (R$)</span>
              <span class="label-text-alt opacity-50 text-[10px]">
                positivo = receita, negativo = despesa
              </span>
            </label>
            <input
              type="number"
              name="amount"
              step="0.01"
              value={field(@form_params, "amount")}
              class="input input-bordered w-full rounded-2xl bg-base-200 border-none font-mono font-bold"
              required
            />
          </div>

          <%!-- The salary marker is global (it clears every other row), so it is only
                offered on an existing item, never at creation. --%>
          <div :if={@modal_mode == :edit} class="form-control">
            <label class="label cursor-pointer justify-start gap-3 p-0 pt-2">
              <input
                type="checkbox"
                name="is_salary"
                checked={@edit_item.is_salary}
                class="checkbox checkbox-primary checkbox-md rounded-lg"
              />
              <span class="label-text text-xs font-semibold opacity-75">
                Marcar como Salário Principal
              </span>
            </label>
          </div>

          <div class="flex flex-col sm:flex-row gap-3 pt-4">
            <button type="submit" class="btn btn-primary btn-md rounded-2xl font-black flex-1">
              Salvar
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

        <button
          :if={@modal_mode == :edit}
          phx-click="resync_item"
          phx-value-id={@edit_item.id}
          class="btn btn-outline btn-md w-full rounded-2xl font-bold gap-2 mt-6"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Ressincronizar com Histórico
        </button>
      </div>
    </.modal>
    """
  end

  attr :commitment, :map, required: true

  defp commitment_detail(assigns) do
    ~H"""
    <span class="block text-[10px] font-semibold text-info">
      Parcela {@commitment.parcel_number}/{@commitment.installments}
      <%= if @commitment.parcel_number == @commitment.installments do %>
        • encerra o compromisso
      <% else %>
        • termina em {end_month(@commitment.ends_on)}
      <% end %>
    </span>
    <span
      :if={@commitment.parcel_number == @commitment.installments}
      class="badge badge-sm badge-success text-[10px] font-black"
    >
      Última parcela
    </span>
    """
  end

  attr :total, :any, required: true
  attr :groups, :list, required: true

  defp installment_disclosure(assigns) do
    ~H"""
    <details class="text-[11px]">
      <summary class="cursor-pointer text-secondary font-semibold">
        dos quais {format_currency(@total)} são parcelas
      </summary>
      <div class="rounded-xl bg-base-200/60 border border-base-300 px-2 py-1 mt-1 divide-y divide-base-300">
        <div :for={group <- @groups} class="flex items-start justify-between gap-2 py-1">
          <div class="min-w-0">
            <span class="block text-[11px] font-bold truncate">{group.description}</span>
            <span :if={group.parcel_number} class="block text-[10px] opacity-60">
              Parcela {group.parcel_number}/{group.installments}
            </span>
          </div>
          <span class="text-[11px] font-black text-error whitespace-nowrap">
            {format_currency(group.parcel_value)}
          </span>
        </div>
      </div>
    </details>
    """
  end

  # Only an :estimado bill discloses installments: a :boleto is a real imported
  # statement and no breakdown is computed for it.
  defp disclose_installments?(occ) do
    Map.get(occ, :origin) == :estimado and Decimal.positive?(occ.installment_total)
  end

  defp minimum_balance(nil, projection), do: projection.starting_balance
  defp minimum_balance(point, _projection), do: point.balance_after

  defp ruler_card_class(occ, critical_date) do
    cond do
      occ.date == critical_date -> "border-warning bg-warning/10"
      Map.get(occ, :origin) -> "border-secondary/30 bg-secondary/5"
      Map.get(occ, :commitment) -> "border-info/30 bg-info/5"
      Decimal.positive?(occ.item.amount) -> "border-success/30 bg-success/5"
      true -> "border-base-300 bg-base-200/40"
    end
  end
end
