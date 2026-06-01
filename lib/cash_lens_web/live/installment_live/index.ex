defmodule CashLensWeb.InstallmentLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Installments

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:show_modal, false)
     |> assign(
       :form,
       to_form(Installments.change_installment_group(%Installments.InstallmentGroup{}))
     )
     |> load_data()}
  end

  defp load_data(socket) do
    upcoming = Installments.upcoming_installments()

    chart_data =
      Enum.map(upcoming, fn m ->
        %{
          label: "#{month_label(m.date.month)}/#{m.date.year - 2000}",
          value: Decimal.to_float(m.total)
        }
      end)

    socket
    |> assign(:groups, list_groups())
    |> assign(:upcoming, upcoming)
    |> assign(:upcoming_chart, Jason.encode!(chart_data))
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
    {:noreply, assign(socket, :show_modal, true)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("save", %{"installment_group" => params}, socket) do
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
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)
    {:ok, _} = Installments.delete_installment_group(group)
    {:noreply, load_data(socket)}
  end

  defp list_groups do
    Installments.list_installment_groups()
    |> Enum.map(fn g -> Installments.get_group_with_progress(g.id) end)
    |> Enum.reject(& &1.is_finished)
    # Fewest remaining parcels first (closest to finishing on top).
    |> Enum.sort_by(& &1.remaining_count)
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
        <div class="h-64">
          <canvas id="upcoming-chart" phx-hook="BarChart" data-chart={@upcoming_chart}></canvas>
        </div>
      </div>

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
              <th class="w-10"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={group <- @groups} class="hover">
              <td class="font-bold text-xs">{group.description_pattern}</td>
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
              <td class="text-right">
                <button
                  phx-click="delete"
                  phx-value-id={group.id}
                  class="btn btn-ghost btn-xs text-error p-0"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.modal :if={@show_modal} id="group-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <div class="w-16 h-16 bg-primary/10 text-primary rounded-full flex items-center justify-center mb-6">
            <.icon name="hero-rectangle-group" class="size-8" />
          </div>
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter">
            Novo Grupo de Parcelamento
          </h2>
          <p class="text-sm opacity-70 mb-8">
            Crie um grupo para acompanhar uma dívida de longo prazo e suas parcelas.
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
              <.input field={@form[:installments]} type="number" label="Total de Parcelas" required />
            </div>
            <.input field={@form[:start_date]} type="date" label="Data de Início" required />

            <div class="flex flex-col sm:flex-row gap-3 pt-4">
              <button
                type="submit"
                class="btn btn-primary btn-lg flex-1 rounded-2xl shadow-lg shadow-primary/20"
              >
                Criar Grupo
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
