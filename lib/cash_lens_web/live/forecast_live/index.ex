defmodule CashLensWeb.ForecastLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Forecast

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_projection(socket)}
  end

  defp assign_projection(socket) do
    items = Forecast.list_recurring_items()
    projection = Forecast.project()
    target_date = Forecast.next_income_date(projection)

    socket
    |> assign(:items, items)
    |> assign(:projection, projection)
    |> assign(:target_date, target_date)
    |> assign(:target_balance, Forecast.balance_on(projection, target_date))
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
  def handle_event("resync_item", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.resync_item(item) do
      {:ok, _} ->
        {:noreply, assign_projection(socket)}

      {:error, :insufficient_history} ->
        {:noreply, put_flash(socket, :error, "Histórico insuficiente para ressincronizar.")}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)
    {:ok, _} = Forecast.toggle_active(item)
    {:noreply, assign_projection(socket)}
  end

  @impl true
  def handle_event("update_day", %{"id" => id, "value" => value}, socket) do
    apply_manual_update(socket, id, %{"day_of_month" => value}, "Dia inválido (use 1 a 31).")
  end

  @impl true
  def handle_event("update_amount", %{"id" => id, "value" => value}, socket) do
    apply_manual_update(socket, id, %{"amount" => value}, "Valor inválido.")
  end

  @impl true
  def handle_event("change_target_date", %{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:noreply,
         socket
         |> assign(:target_date, date)
         |> assign(:target_balance, Forecast.balance_on(socket.assigns.projection, date))}

      :error ->
        {:noreply, socket}
    end
  end

  defp apply_manual_update(socket, id, attrs, error_message) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.manual_update(item, attrs) do
      {:ok, _} -> {:noreply, assign_projection(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Previsão
        <:subtitle>
          Projeção de saldo das contas não-cartão de crédito, com base nas suas contas fixas.
        </:subtitle>
        <:actions>
          <button phx-click="sync_all" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="size-4 mr-1" /> Sincronizar com Histórico
          </button>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title">Saldo Zera Em</div>
            <div class={[
              "stat-value text-2xl font-black",
              if(@projection.zero_date, do: "text-error", else: "text-success")
            ]}>
              <%= if @projection.zero_date do %>
                {format_date(@projection.zero_date)}
              <% else %>
                Não fica negativo
              <% end %>
            </div>
            <div class="stat-desc">Próximos 90 dias</div>
          </div>
        </div>

        <div class="stats shadow bg-base-100 border border-base-300">
          <div class="stat">
            <div class="stat-title flex items-center gap-2">
              <span>Saldo em</span>
              <form phx-change="change_target_date">
                <input
                  type="date"
                  name="date"
                  value={Date.to_iso8601(@target_date)}
                  class="input input-bordered input-xs"
                />
              </form>
            </div>
            <div class="stat-value text-2xl font-black text-primary">
              {format_currency(@target_balance)}
            </div>
          </div>
        </div>
      </div>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Conta</th>
              <th class="w-24 text-center">Dia</th>
              <th class="w-32 text-right">Valor</th>
              <th class="w-20 text-center">Ativo</th>
              <th class="w-20 text-center"></th>
              <th class="w-16"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @items} class={["hover", !item.active && "opacity-40"]}>
              <td class="font-bold">{item.label}</td>
              <td class="text-center">
                <input
                  type="number"
                  min="1"
                  max="31"
                  value={item.day_of_month}
                  phx-blur="update_day"
                  phx-value-id={item.id}
                  class="input input-bordered input-xs w-16 text-center"
                />
              </td>
              <td class="text-right">
                <input
                  type="number"
                  step="0.01"
                  value={item.amount}
                  phx-blur="update_amount"
                  phx-value-id={item.id}
                  class="input input-bordered input-xs w-28 text-right"
                />
              </td>
              <td class="text-center">
                <button phx-click="toggle_active" phx-value-id={item.id} class="btn btn-ghost btn-xs">
                  <.icon
                    name={if item.active, do: "hero-check-circle", else: "hero-x-circle"}
                    class={["size-5", if(item.active, do: "text-success", else: "text-base-300")]}
                  />
                </button>
              </td>
              <td class="text-center">
                <span :if={item.manually_edited} class="badge badge-ghost badge-sm text-[9px]">
                  Manual
                </span>
              </td>
              <td class="text-center">
                <button
                  phx-click="resync_item"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs"
                  title="Ressincronizar"
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                </button>
              </td>
            </tr>
            <tr :if={@items == []}>
              <td colspan="6" class="text-center py-8 opacity-50">
                Nenhuma conta fixa detectada ainda. Clique em "Sincronizar com Histórico".
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
