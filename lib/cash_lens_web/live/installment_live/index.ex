defmodule CashLensWeb.InstallmentLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Installments

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:groups, list_groups())
     |> assign(:show_modal, false)
     |> assign(
       :form,
       to_form(Installments.change_installment_group(%Installments.InstallmentGroup{}))
     )}
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
         |> assign(:groups, list_groups())
         |> put_flash(:success, "Grupo de parcelamento criado!")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    group = Installments.get_installment_group!(id)
    {:ok, _} = Installments.delete_installment_group(group)
    {:noreply, assign(socket, :groups, list_groups())}
  end

  defp list_groups do
    Installments.list_installment_groups()
    |> Enum.map(fn g -> Installments.get_group_with_progress(g.id) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div class="flex items-center justify-between">
        <h1 class="text-3xl font-bold text-base-content uppercase tracking-tighter">
          Grupos de Parcelamento
        </h1>
        <button phx-click="open_modal" class="btn btn-primary btn-sm rounded-xl">
          <.icon name="hero-plus" class="size-4 mr-1" /> Novo Grupo
        </button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%= for group <- @groups do %>
          <div class="card bg-base-100 border border-base-300 shadow-sm overflow-hidden">
            <div class="card-body p-6">
              <div class="flex items-start justify-between">
                <div>
                  <h2 class="text-xs font-black uppercase opacity-50 mb-1">
                    {group.description_pattern}
                  </h2>
                  <p class="text-2xl font-black text-primary">
                    {if group.total_amount, do: format_currency(group.total_amount), else: "---"}
                  </p>
                </div>
                <button
                  phx-click="delete"
                  phx-value-id={group.id}
                  class="btn btn-ghost btn-xs text-error p-0"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>

              <div class="mt-6 space-y-2">
                <div class="flex items-center justify-between text-[10px] font-bold uppercase">
                  <span class="opacity-50">Progresso</span>
                  <span>{group.paid_count} / {group.installments} pagos</span>
                </div>
                <progress
                  class="progress progress-primary w-full h-2"
                  value={group.paid_count}
                  max={group.installments}
                >
                </progress>
                <p class="text-[10px] opacity-40 font-medium">
                  Iniciado em {format_date(group.start_date)}
                </p>
              </div>
            </div>
          </div>
        <% end %>
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
