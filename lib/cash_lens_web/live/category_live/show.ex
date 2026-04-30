defmodule CashLensWeb.CategoryLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-xl mx-auto py-8">
      <.header>
        Category: {@category.name}
        <:subtitle>Classification details and associated rules.</:subtitle>
        <:actions>
          <.link navigate={~p"/categories/#{@category}/edit"}>
            <.button variant="primary">Edit Category</.button>
          </.link>
        </:actions>
      </.header>

      <.list>
        <:item title="Name">{@category.name}</:item>
        <:item title="Slug">{@category.slug}</:item>
        <:item title="Parent Category">
          {if @category.parent, do: @category.parent.name, else: "Main"}
        </:item>
        <:item title="Keywords">
          <span class="italic opacity-60">{@category.keywords || "No rules defined"}</span>
        </:item>
      </.list>

      <div class="mt-8">
        <.link navigate={~p"/categories"} class="text-sm font-semibold">
          <.icon name="hero-arrow-left" class="size-3 mr-1" /> Back to list
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     assign(socket, :category, Categories.get_category!(id) |> CashLens.Repo.preload(:parent))}
  end
end
