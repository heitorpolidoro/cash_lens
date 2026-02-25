defmodule CashLensWeb.CategoryLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
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
        <div class="sr-only">
          <.link navigate={~p"/categories/#{category}"}>Exibir</.link>
        </div>
        <.link navigate={~p"/categories/#{category}/edit"}>Editar</.link>
      </:action>
      <:action :let={{id, category}}>
        <.link
          phx-click={JS.push("delete", value: %{id: category.id}) |> hide("##{id}")}
          data-confirm="Tem certeza?"
        >
          Excluir
        </.link>
      </:action>
    </.table>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Categorias")
     |> stream(:categories, list_categories())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    {:ok, _} = Categories.delete_category(category)

    {:noreply, stream_delete(socket, :categories, category)}
  end

  defp list_categories() do
    Categories.list_categories()
  end
end
