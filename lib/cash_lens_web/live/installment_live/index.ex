defmodule CashLensWeb.InstallmentLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Installments

  @impl true
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

  defp load_data(socket) do
    socket
    |> assign(:groups, list_groups(socket.assigns.filters))
    |> assign(:filters_active?, filters_active?(socket.assigns.filters))
    |> assign(:upcoming, Installments.upcoming_installments())
  end

  @impl true
  def handle_event("detect_installments", _params, socket) do
    count = Installments.scan_and_apply_all()

    {:noreply,
     socket
     |> load_data()
     |> put_flash(:success, "#{count} transação(ões) parcelada(s) detectada(s) e agrupada(s).")}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(
       :form,
       to_form(Installments.change_installment_group(%Installments.InstallmentGroup{}))
     )}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)

    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:form, to_form(Installments.change_installment_group(group)))}
  end

  @impl true
  def handle_event("save", %{"installment_group" => params}, socket) do
    group = socket.assigns.form.data

    case group.id do
      nil ->
        case Installments.create_installment_group(params) do
          {:ok, _group} ->
            {:noreply,
             socket
             |> assign(:show_modal, false)
             |> load_data()
             |> put_flash(:success, "Grupo de parcelamento criado!")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      _id ->
        case Installments.update_installment_group(group, params) do
          {:ok, _group} ->
            {:noreply,
             socket
             |> assign(:show_modal, false)
             |> load_data()
             |> put_flash(:success, "Grupo de parcelamento atualizado!")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)
    {:ok, _} = Installments.delete_installment_group(group)
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)
    {:noreply, socket |> assign(:filters, filters) |> load_data()}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:filters, default_filters()) |> load_data()}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_ids, id),
        do: MapSet.delete(socket.assigns.expanded_ids, id),
        else: MapSet.put(socket.assigns.expanded_ids, id)

    {:noreply, assign(socket, :expanded_ids, expanded)}
  end

  defp list_groups(filters) do
    Installments.list_installment_groups()
    |> Enum.map(fn g -> Installments.get_group_with_progress(g.id) end)
    |> Enum.reject(& &1.is_finished)
    |> Enum.filter(&matches_filters?(&1, filters))
    # Fewest remaining parcels first (closest to finishing on top).
    |> Enum.sort_by(& &1.remaining_count)
    |> zebra_by_remaining()
  end

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
    do:
      String.contains?(String.downcase(group.description_pattern || ""), String.downcase(needle))

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

  # Adds a :band (0/1) that flips whenever the remaining-parcels count changes, so the
  # table can be striped by "parcelas faltantes" (each remaining-count block one shade).
  defp zebra_by_remaining(groups) do
    {rows, _prev, _band} =
      Enum.reduce(groups, {[], nil, 0}, fn g, {acc, prev, band} ->
        band = if prev != nil and g.remaining_count != prev, do: 1 - band, else: band
        {[Map.put(g, :band, band) | acc], g.remaining_count, band}
      end)

    Enum.reverse(rows)
  end

  defp parcel_status(%{date: %Date{} = d}) do
    if Date.compare(d, Date.utc_today()) == :gt, do: "a vencer", else: "paga"
  end

  defp parcel_status(_), do: "—"

  defp last_parcel_label(group) do
    case Installments.last_installment_date(group) do
      %Date{} = d ->
        yy = d.year |> Integer.to_string() |> String.slice(-2, 2)
        "#{String.downcase(month_label(d.month))}/#{yy}"

      _ ->
        "---"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div class="flex items-center justify-between">
        <h1 class="text-3xl font-bold text-base-content uppercase tracking-tighter">
          Grupos de Parcelamento
        </h1>
        <div class="flex items-center gap-2">
          <button
            phx-click="detect_installments"
            phx-disable-with="Detectando..."
            class="btn btn-ghost btn-sm rounded-xl"
          >
            <.icon name="hero-sparkles" class="size-4 mr-1" /> Detectar Parcelamentos
          </button>
          <button phx-click="open_modal" class="btn btn-primary btn-sm rounded-xl">
            <.icon name="hero-plus" class="size-4 mr-1" /> Novo Grupo
          </button>
        </div>
      </div>

      <%!-- Projeção de gastos com parcelas nos próximos meses --%>
      <div :if={@upcoming != []} class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-5">
        <h2 class="text-[11px] font-black uppercase tracking-widest opacity-50 mb-3">
          Parcelas nos próximos meses
        </h2>
        <div class="flex gap-3 overflow-x-auto pb-1">
          <div
            :for={m <- @upcoming}
            class={[
              "shrink-0 min-w-[120px] rounded-xl border px-4 py-3",
              if(m.pending,
                do: "border-warning/40 bg-warning/10",
                else: "border-base-300 bg-base-200/40"
              )
            ]}
          >
            <div class="text-[10px] font-bold uppercase opacity-50">
              {month_name(m.date.month)}/{m.date.year}
            </div>
            <div class={[
              "text-lg font-black",
              if(m.pending, do: "text-warning", else: "text-primary")
            ]}>
              {format_currency(m.total)}
            </div>
            <div
              :if={m.pending}
              class="text-[9px] font-bold uppercase text-warning flex items-center gap-1 mt-0.5"
            >
              <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Falta importar
            </div>
          </div>
        </div>
      </div>

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

      <%!-- Lista de grupos de parcelamento --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div :if={@groups == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhum parcelamento ativo.
        </div>

        <table :if={@groups != []} class="table table-sm w-full">
          <thead class="bg-base-200/50 text-[10px] uppercase tracking-wider">
            <tr>
              <th>Descrição</th>
              <th class="text-right">Valor Total</th>
              <th class="text-right">Parcela</th>
              <th class="text-center w-40">Progresso</th>
              <th class="text-right">Início</th>
              <th class="text-right">Última Parcela</th>
              <th class="w-10"></th>
            </tr>
          </thead>
          <tbody>
            <%= for group <- @groups do %>
              <tr class={["hover", if(group.band == 0, do: "bg-base-100", else: "bg-base-300")]}>
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
                <td class="text-right font-mono">
                  {if group.total_amount, do: format_currency(group.total_amount), else: "---"}
                </td>
                <td class="text-right font-mono text-xs opacity-70">
                  {if group.total_amount && group.installments > 0,
                    do:
                      format_currency(
                        Decimal.round(Decimal.div(group.total_amount, group.installments), 2)
                      ),
                    else: "---"}
                </td>
                <td>
                  <div class="flex flex-col gap-1">
                    <span class="text-[10px] font-bold text-center">
                      {group.paid_count} / {group.installments}
                    </span>
                    <progress
                      class="progress progress-primary w-full h-1.5"
                      value={group.paid_count}
                      max={group.installments}
                    >
                    </progress>
                  </div>
                </td>
                <td class="text-right text-xs opacity-60 whitespace-nowrap">
                  {format_date(group.start_date)}
                </td>
                <td class="text-right text-xs opacity-60 whitespace-nowrap">
                  {last_parcel_label(group)}
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-1.5">
                    <button
                      phx-click="edit"
                      phx-value-id={group.id}
                      class="btn btn-ghost btn-xs text-info p-0"
                    >
                      <.icon name="hero-pencil" class="size-4" />
                    </button>
                    <button
                      phx-click="delete"
                      phx-value-id={group.id}
                      class="btn btn-ghost btn-xs text-error p-0"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
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
                          <td class="text-right text-xs opacity-60 whitespace-nowrap">
                            {format_date(p.date)}
                          </td>
                          <td class="text-right font-mono text-xs">{format_currency(p.amount)}</td>
                          <td class="text-right text-[10px] uppercase opacity-60">
                            {parcel_status(p)}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <.modal :if={@show_modal} id="group-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <div class="w-16 h-16 bg-primary/10 text-primary rounded-full flex items-center justify-center mb-6">
            <.icon name="hero-rectangle-group" class="size-8" />
          </div>
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter">
            {if @form.data.id, do: "Editar Grupo de Parcelamento", else: "Novo Grupo de Parcelamento"}
          </h2>
          <p class="text-sm opacity-70 mb-8">
            {if @form.data.id,
              do: "Edite as configurações do grupo de parcelamento.",
              else: "Crie um grupo para acompanhar uma dívida de longo prazo e suas parcelas."}
          </p>

          <.form for={@form} phx-submit="save" class="space-y-4">
            <.input
              field={@form[:description_pattern]}
              label="Padrão de Descrição (corresponde às importações do banco)"
              placeholder="Ex: NUBANK, ALUGUEL..."
              required
            />
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:total_amount]}
                type="number"
                step="0.01"
                label="Valor Total (opcional)"
              />
              <.input
                field={@form[:installment_amount]}
                type="number"
                step="0.01"
                label="Valor da Parcela (opcional)"
              />
            </div>
            <div class="grid grid-cols-2 gap-4">
              <.input field={@form[:installments]} type="number" label="Total de Parcelas" required />
              <.input field={@form[:start_date]} type="date" label="Data de Início" required />
            </div>

            <div class="flex flex-col sm:flex-row gap-3 pt-4">
              <button
                type="submit"
                class="btn btn-primary btn-lg flex-1 rounded-2xl shadow-lg shadow-primary/20"
              >
                {if @form.data.id, do: "Salvar Alterações", else: "Criar Grupo"}
              </button>
              <button
                type="button"
                phx-click="close_modal"
                class="btn btn-ghost btn-lg flex-1 rounded-2xl"
              >
                Cancelar
              </button>
            </div>
          </.form>
        </div>
      </.modal>
    </div>
    """
  end
end
