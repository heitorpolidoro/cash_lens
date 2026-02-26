defmodule CashLensWeb.CategoryLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Listando Categorias
        <:actions>
          <.link navigate={~p"/categories/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Categoria
            </.button>
          </.link>
        </:actions>
      </.header>

      <.table
        id="categories"
        rows={@streams.categories}
        row_click={fn {_id, category} -> JS.navigate(~p"/categories/#{category}") end}
      >
        <:col :let={{_id, category}} label="Nome">{category.name}</:col>
        <:col :let={{_id, category}} label="Slug">{category.slug}</:col>
        <:action :let={{_id, category}}>
          <div class="flex gap-2">
            <.link navigate={~p"/categories/#{category}/edit"} class="btn btn-ghost btn-xs">Editar</.link>
            <button phx-click="confirm_delete" phx-value-id={category.id} class="btn btn-ghost btn-xs text-error">Excluir</button>
          </div>
        </:action>
      </.table>
    </div>

    <!-- Modal de Confirmação -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Excluir Categoria?</h2>
        <p class="text-base-content/60 mb-10">Deseja realmente apagar esta categoria?</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">Sim, Apagar</button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">Cancelar</button>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Categorias")
     |> assign(:confirm_modal, nil)
     |> stream(:categories, Categories.list_categories())}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, :confirm_modal, nil)}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    {:ok, _} = Categories.delete_category(category)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:categories, category)}
  end
end
