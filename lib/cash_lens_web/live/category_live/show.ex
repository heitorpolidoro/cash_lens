defmodule CashLensWeb.CategoryLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-xl mx-auto py-8">
      <.header>
        Category: {@category.name}
        <:subtitle>Detalhes de classificação e regras associadas.</:subtitle>
        <:actions>
          <.link navigate={~p"/categories/#{@category}/edit"}>
            <.button variant="primary">Editar Categoria</.button>
          </.link>
        </:actions>
      </.header>

      <.list>
        <:item title="Nome">{@category.name}</:item>
        <:item title="Slug">{@category.slug}</:item>
        <:item title="Categoria Pai">
          {if @category.parent, do: @category.parent.name, else: "Principal"}
        </:item>
        <:item title="Palavras-chave">
          <span class="italic opacity-60">{@category.keywords || "Nenhuma regra definida"}</span>
        </:item>
      </.list>

      <div class="mt-8">
        <.link navigate={~p"/categories"} class="text-sm font-semibold">
          <.icon name="hero-arrow-left" class="size-3 mr-1" /> Voltar à lista
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign_category(socket, id)}
  end

  # Another user's category is indistinguishable from a missing one: back to the
  # list, never rendering its data.
  defp assign_category(socket, id) do
    assign(socket, :category, Categories.get_category!(socket.assigns.current_user, id))
  rescue
    Ecto.NoResultsError ->
      socket
      |> put_flash(:error, "Categoria não encontrada.")
      |> push_navigate(to: ~p"/categories")
  end
end
