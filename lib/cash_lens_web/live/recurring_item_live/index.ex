defmodule CashLensWeb.RecurringItemLive.Index do
  @moduledoc """
  The registered monthly accounts, as a screen of their own.

  They were only reachable from inside the forecast, which is one of the places
  that reads them -- the dashboard's bill list is another, and they drive the
  projection itself. A cadastro that several screens depend on belongs beside
  the other cadastros, not inside one of its readers.

  One item per category is the rule the detection depends on: `sync_all/0` finds
  an item by its category, so a second one for the same category would have no
  owner. The form therefore offers only categories that are still free, exactly
  as the forecast's modal does.
  """

  use CashLensWeb, :live_view

  alias CashLens.Forecast
  alias CashLens.Forecast.RecurringItem

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Contas Recorrentes")
     |> assign(:recurring_sync_refresh, &load_items/1)
     |> load_items()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:modal, :new)
    |> assign(:item, %RecurringItem{active: true})
    |> assign(:form, to_form(Forecast.change_recurring_item(%RecurringItem{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = Forecast.get_recurring_item!(id)

    socket
    |> assign(:modal, :edit)
    |> assign(:item, item)
    |> assign(:form, to_form(Forecast.change_recurring_item(item)))
  end

  defp apply_action(socket, _index, _params) do
    socket |> assign(:modal, nil) |> assign(:item, nil)
  end

  @impl true
  def handle_event("validate", %{"recurring_item" => params}, socket) do
    changeset =
      socket.assigns.item
      |> Forecast.change_recurring_item(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"recurring_item" => params}, socket) do
    save(socket, socket.assigns.modal, params)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    {:ok, updated} = id |> Forecast.get_recurring_item!() |> Forecast.toggle_active()
    state = if updated.active, do: "ativada", else: "desativada"

    {:noreply, socket |> load_items() |> put_flash(:info, "#{updated.label} #{state}.")}
  end

  def handle_event("resync", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)

    case Forecast.resync_item(item) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> load_items()
         |> put_flash(:info, "#{updated.label} ressincronizada com o histórico.")}

      {:error, :insufficient_history} ->
        {:noreply, put_flash(socket, :error, "#{item.label}: histórico insuficiente.")}

      {:error, :no_recent_occurrence} ->
        {:noreply,
         put_flash(socket, :error, "#{item.label}: sem ocorrência desde antes do mês passado.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    item = Forecast.get_recurring_item!(id)
    {:ok, _} = Forecast.delete_recurring_item(item)

    {:noreply,
     socket
     |> load_items()
     |> put_flash(:info, "#{item.label} excluída. A categoria voltou a ficar livre.")}
  end

  # A hand-created item is marked as edited by hand, like any other hand-typed
  # day or amount: the next sync must not quietly overwrite what was just typed.
  defp save(socket, :new, params) do
    case Forecast.create_recurring_item(Map.put(params, "manually_edited", true)) do
      {:ok, item} ->
        {:noreply,
         socket
         |> load_items()
         |> put_flash(:info, "#{item.label} cadastrada.")
         |> push_patch(to: ~p"/recurring_items")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Forecast.manual_update(socket.assigns.item, params) do
      {:ok, item} ->
        {:noreply,
         socket
         |> load_items()
         |> put_flash(:info, "#{item.label} atualizada.")
         |> push_patch(to: ~p"/recurring_items")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp load_items(socket) do
    items = Forecast.list_recurring_items_with_category()

    socket
    |> assign(:items, items)
    |> assign(:free_categories, Forecast.list_categories_without_recurring_item())
    |> assign(:monthly_total, monthly_total(items))
  end

  # What the active expenses commit to every month. Income is left out: the
  # number answers "how much is spoken for", not "what is the net".
  defp monthly_total(items) do
    items
    |> Enum.filter(&(&1.active and Decimal.negative?(&1.amount)))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, Decimal.abs(&1.amount)))
  end

  defp category_name(%{category: %{name: name}}), do: name
  defp category_name(_item), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6 max-w-7xl mx-auto">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 pb-2 border-b border-base-300">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Contas Recorrentes</h1>
          <p class="text-xs opacity-50 mt-1">
            As contas fixas que a previsão projeta todo mês. Uma por categoria.
          </p>
        </div>
        <div class="flex items-center gap-4 shrink-0">
          <div class="flex items-center gap-2">
            <span class="text-xs opacity-60 font-medium">Comprometido por mês:</span>
            <strong id="monthly-total" class="text-base font-black">
              {format_currency(@monthly_total)}
            </strong>
          </div>
          <.link
            patch={~p"/recurring_items/new"}
            id="new-recurring-item"
            class="btn btn-sm btn-primary rounded-xl font-bold gap-1.5"
          >
            <.icon name="hero-plus" class="size-4" /> Nova Conta
          </.link>
        </div>
      </div>

      <div
        :if={@items == []}
        id="empty-state"
        class="card bg-base-100 border border-base-300 rounded-2xl p-12 text-center"
      >
        <p class="opacity-40 italic text-sm">
          Nenhuma conta recorrente cadastrada. Importar um extrato detecta as que se repetem.
        </p>
      </div>

      <div
        :if={@items != []}
        class="card bg-base-100 border border-base-300 shadow-sm rounded-2xl overflow-hidden"
      >
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>Conta</th>
              <th>Categoria</th>
              <th class="text-center">Dia</th>
              <th class="text-right">Valor</th>
              <th class="text-center">Origem</th>
              <th class="w-40"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={item <- @items}
              id={"recurring-item-#{item.id}"}
              class={["hover", !item.active && "opacity-40"]}
            >
              <td class="font-bold">
                {item.label}
                <span :if={item.is_salary} class="badge badge-success badge-xs ml-1">salário</span>
                <span :if={!item.active} class="badge badge-ghost badge-xs ml-1">desativada</span>
              </td>
              <td class="text-xs opacity-60">{category_name(item)}</td>
              <td class="text-center font-mono text-xs">{item.day_of_month}</td>
              <td class={[
                "text-right font-mono font-black",
                Decimal.negative?(item.amount) && "text-error",
                !Decimal.negative?(item.amount) && "text-success"
              ]}>
                {format_currency(item.amount)}
              </td>
              <td class="text-center">
                <%!--
                  Which numbers the next sync may rewrite. An item edited by hand
                  is left alone by it, and that is the only thing the badge says.
                --%>
                <span class={[
                  "badge badge-xs",
                  if(item.manually_edited, do: "badge-warning", else: "badge-ghost")
                ]}>
                  {if item.manually_edited, do: "manual", else: "detectada"}
                </span>
              </td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <.link
                    patch={~p"/recurring_items/#{item.id}/edit"}
                    id={"edit-#{item.id}"}
                    class="btn btn-ghost btn-xs"
                    title="Editar"
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </.link>
                  <button
                    id={"resync-#{item.id}"}
                    phx-click="resync"
                    phx-value-id={item.id}
                    class="btn btn-ghost btn-xs"
                    title="Ressincronizar com o histórico"
                  >
                    <.icon name="hero-arrow-path" class="size-4" />
                  </button>
                  <button
                    id={"toggle-#{item.id}"}
                    phx-click="toggle_active"
                    phx-value-id={item.id}
                    class="btn btn-ghost btn-xs"
                    title={if item.active, do: "Desativar", else: "Ativar"}
                  >
                    <.icon
                      name={if item.active, do: "hero-pause-circle", else: "hero-play-circle"}
                      class="size-4"
                    />
                  </button>
                  <%!--
                    Deleting frees the category, and the next sync may recreate
                    the item from history. Switching off is the reversible one,
                    so deleting asks first.
                  --%>
                  <button
                    id={"delete-#{item.id}"}
                    phx-click="delete"
                    phx-value-id={item.id}
                    data-confirm={"Excluir #{item.label}? A categoria volta a ficar livre e a próxima sincronização pode recriá-la a partir do histórico."}
                    class="btn btn-ghost btn-xs text-error"
                    title="Excluir"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.modal :if={@modal} id="recurring-item-modal" show on_cancel={JS.patch(~p"/recurring_items")}>
        <h2 class="text-lg font-black uppercase tracking-tight mb-4">
          {if @modal == :new, do: "Nova Conta Recorrente", else: "Editar Conta"}
        </h2>

        <.form for={@form} id="recurring-item-form" phx-change="validate" phx-submit="save">
          <%!--
            The category is chosen once, at creation, and only among the free
            ones: the sync finds an item by its category, so a second item for
            the same category would have no owner.
          --%>
          <.input
            :if={@modal == :new}
            field={@form[:category_id]}
            type="select"
            label="Categoria"
            options={[{"Selecione...", ""}] ++ Enum.map(@free_categories, &{&1.name, &1.id})}
          />
          <p
            :if={@modal == :new and @free_categories == []}
            id="no-free-categories"
            class="text-xs text-warning mb-2"
          >
            Toda categoria já tem uma conta recorrente. Exclua uma, ou marque outra categoria como Fixo.
          </p>
          <div :if={@modal == :edit} class="mb-3">
            <span class="text-xs font-bold opacity-60">Categoria</span>
            <p class="text-sm font-bold">{category_name(@item)}</p>
          </div>

          <.input field={@form[:label]} type="text" label="Nome" />
          <.input field={@form[:day_of_month]} type="number" label="Dia do mês" min="1" max="31" />
          <.input field={@form[:amount]} type="text" label="Valor (negativo para despesa)" />
          <.input field={@form[:is_salary]} type="checkbox" label="É o salário" />
          <.input :if={@modal == :edit} field={@form[:active]} type="checkbox" label="Ativa" />

          <div class="flex items-center justify-end gap-2 pt-4">
            <.link patch={~p"/recurring_items"} class="btn btn-ghost">Cancelar</.link>
            <button type="submit" phx-disable-with="Salvando..." class="btn btn-primary">
              Salvar
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end
end
