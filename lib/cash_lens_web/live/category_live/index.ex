defmodule CashLensWeb.CategoryLive.Index do
  @moduledoc """
  The categories screen (CL-16).

  Categories are shown as a hierarchical tree — one card per root category with
  its subcategories nested inside — instead of a flat table, and
  `/categories/new` and `/categories/:id/edit` mount this same LiveView so the
  form opens as an overlaid modal (still reachable as a deep link).

  Expand/collapse is server-side state (`@collapsed_groups`) rather than
  `JS.toggle`, so a group the user closed stays closed across the re-renders
  caused by filtering, searching and saving.
  """

  use CashLensWeb, :live_view

  alias CashLens.Categories
  alias CashLens.Categories.Category
  alias CashLensWeb.CategoryLive.FormComponent

  @type_tabs [
    {"all", "Todas"},
    {"fixed", "Custos Fixos"},
    {"variable", "Variáveis"},
    {"reimbursable", "Reembolsáveis"}
  ]

  # Root categories have no icon column in the database (a schema change is out
  # of scope), so a representative emoji is derived from the name, with a
  # neutral folder as the fallback.
  @emojis [
    {~w(moradia casa aluguel), "🏠"},
    {~w(aliment mercado comida restaurante), "🛒"},
    {~w(saude saúde medic farmacia farmácia), "🩺"},
    {~w(transporte carro combustivel combustível uber), "🚗"},
    {~w(lazer viagem viagens entretenimento), "🎉"},
    {~w(educacao educação escola curso), "🎓"},
    {~w(salario salário renda receita), "💰"},
    {~w(assinatura streaming servico serviço), "📺"},
    {~w(pet animal), "🐾"},
    {~w(imposto taxa banco tarifa), "🏦"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 pb-2 border-b border-base-300">
        <div>
          <h1 class="text-2xl font-black tracking-tighter">Árvore de Categorias</h1>
          <p class="text-xs text-base-content/60 mt-0.5">
            Organize despesas e receitas em grupos hierárquicos e configure regras automáticas por
            palavras-chave.
          </p>
        </div>

        <div class="flex items-center gap-3">
          <button id="expand-all" type="button" phx-click="expand_all" class="btn btn-ghost btn-sm">
            Expandir Todos
          </button>
          <button
            id="collapse-all"
            type="button"
            phx-click="collapse_all"
            class="btn btn-ghost btn-sm"
          >
            Recolher Todos
          </button>
          <.link id="new-category-button" patch={~p"/categories/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Categoria
            </.button>
          </.link>
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 p-4 shadow-sm flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div class="flex items-center gap-1.5 p-1 bg-base-200 rounded-xl overflow-x-auto text-xs font-bold">
          <button
            :for={{value, label} <- @type_tabs}
            id={"tab-#{value}"}
            type="button"
            phx-click="filter_type"
            phx-value-type={value}
            class={[
              "px-3 py-1.5 rounded-lg transition",
              if(@type_filter == value,
                do: "bg-base-100 text-primary shadow-sm",
                else: "text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <form id="category-search-form" phx-change="search" class="relative flex-1 max-w-sm">
          <input
            type="text"
            name="search"
            value={@search}
            placeholder="Buscar categoria ou palavra-chave..."
            phx-debounce="200"
            class="input input-bordered input-sm w-full"
          />
        </form>
      </div>

      <div id="category-tree" class="space-y-4">
        <p :if={@tree == []} class="text-sm text-base-content/50">
          Nenhuma categoria encontrada.
        </p>

        <.root_card
          :for={{root, children} <- @tree}
          root={root}
          children={children}
          collapsed={MapSet.member?(@collapsed_groups, root.id)}
          fixo_hint={@fixo_hint}
        />
      </div>
    </div>

    <.live_component
      :if={@form_action}
      module={FormComponent}
      id="category-form-component"
      action={@form_action}
      category={@form_category}
      parent_id={@form_parent_id}
    />

    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 space-y-4">
        <h2 class="text-2xl font-black">Excluir Categoria?</h2>
        <p id="confirm-delete-body" class="text-base-content/70">{@confirm_modal.body}</p>
        <div class="flex flex-col sm:flex-row gap-3 pt-4">
          <button
            id="confirm-delete-button"
            type="button"
            phx-click="delete"
            phx-value-id={@confirm_modal.id}
            disabled={@confirm_modal.has_children}
            class="btn btn-error flex-1 rounded-2xl"
          >
            Excluir
          </button>
          <button
            type="button"
            phx-click="close_modal"
            class="btn btn-ghost flex-1 rounded-2xl"
          >
            Cancelar
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :root, Category, required: true
  attr :children, :list, required: true
  attr :collapsed, :boolean, required: true
  attr :fixo_hint, :string, required: true

  defp root_card(assigns) do
    ~H"""
    <div
      id={"category-#{@root.id}"}
      class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden"
    >
      <div class="p-4 bg-base-200/40 flex items-center justify-between gap-3 border-b border-base-300">
        <div class="flex items-center gap-3 min-w-0">
          <button
            id={"toggle-group-#{@root.id}"}
            type="button"
            phx-click="toggle_group"
            phx-value-id={@root.id}
            class="btn btn-ghost btn-xs px-1"
            title={if @collapsed, do: "Expandir subcategorias", else: "Recolher subcategorias"}
            aria-label={if @collapsed, do: "Expandir subcategorias", else: "Recolher subcategorias"}
          >
            <.icon
              name={if @collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-4"
            />
          </button>

          <div class="size-8 rounded-xl bg-base-200 flex items-center justify-center text-base">
            {category_emoji(@root)}
          </div>

          <div class="min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="text-sm font-bold">{@root.name}</span>
              <button
                id={"toggle-type-#{@root.id}"}
                type="button"
                phx-click="toggle_fixed"
                phx-value-id={@root.id}
                title={@fixo_hint}
                aria-label={"Alternar tipo de gasto de #{@root.name}"}
                class={[
                  "px-2 py-0.5 rounded-full text-[10px] font-extrabold border",
                  if(@root.type == "fixed",
                    do: "bg-info/10 text-info border-info/30",
                    else: "bg-warning/10 text-warning border-warning/30"
                  )
                ]}
              >
                {type_label(@root.type)}
              </button>
              <span
                :if={@root.default_reimbursable}
                class="px-2 py-0.5 rounded-full text-[10px] font-extrabold bg-primary/10 text-primary border border-primary/30"
              >
                Reembolsável por Padrão
              </span>
            </div>
            <span class="text-[11px] text-base-content/50 font-medium">
              {subcategories_label(@children)}
            </span>
            <div :if={keyword_list(@root) != []} class="flex flex-wrap gap-1 mt-1">
              <span :for={keyword <- keyword_list(@root)} class="badge badge-ghost badge-xs font-mono">
                {keyword}
              </span>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <.link
            id={"add-subcategory-#{@root.id}"}
            patch={~p"/categories/new?parent_id=#{@root.id}"}
            class="btn btn-outline btn-primary btn-xs rounded-lg"
          >
            <.icon name="hero-plus" class="size-3 mr-1" /> Subcategoria
          </.link>
          <.link
            id={"edit-category-#{@root.id}"}
            patch={~p"/categories/#{@root.id}/edit"}
            class="btn btn-ghost btn-xs px-1"
            title="Editar categoria"
            aria-label="Editar categoria"
          >
            <.icon name="hero-pencil" class="size-4" />
          </.link>
          <button
            id={"delete-category-#{@root.id}"}
            type="button"
            phx-click="confirm_delete"
            phx-value-id={@root.id}
            class="btn btn-ghost btn-xs px-1 text-error"
            title="Excluir categoria"
            aria-label="Excluir categoria"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <div :if={!@collapsed} id={"group-#{@root.id}"} class="p-2 space-y-1">
        <p :if={@children == []} class="text-xs text-base-content/40 px-3 py-2">
          Nenhuma subcategoria.
        </p>
        <.subcategory_row :for={child <- @children} category={child} fixo_hint={@fixo_hint} />
      </div>
    </div>
    """
  end

  attr :category, Category, required: true
  attr :fixo_hint, :string, required: true

  defp subcategory_row(assigns) do
    ~H"""
    <div
      id={"category-#{@category.id}"}
      class="flex flex-col sm:flex-row sm:items-center justify-between p-3 rounded-xl hover:bg-base-200/50 transition gap-2"
    >
      <div class="flex items-center gap-3 pl-8">
        <div class="size-2 rounded-full bg-primary/60"></div>
        <div>
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-xs font-bold">{@category.name}</span>
            <span
              :if={@category.default_reimbursable}
              class="text-[9px] bg-primary/10 text-primary font-extrabold px-1.5 py-0.5 rounded"
            >
              Marca Reembolso
            </span>
          </div>
          <div :if={keyword_list(@category) != []} class="flex flex-wrap gap-1 mt-1">
            <span
              :for={keyword <- keyword_list(@category)}
              class="badge badge-ghost badge-xs font-mono"
            >
              {keyword}
            </span>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-4 self-end sm:self-center">
        <label
          class="flex items-center gap-1.5 text-[11px] font-semibold text-base-content/60 cursor-pointer"
          title={@fixo_hint}
        >
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-secondary"
            checked={@category.type == "fixed"}
            phx-click="toggle_fixed"
            phx-value-id={@category.id}
          /> Fixo
        </label>
        <.link
          id={"edit-category-#{@category.id}"}
          patch={~p"/categories/#{@category.id}/edit"}
          class="btn btn-ghost btn-xs px-1"
          title="Editar subcategoria"
          aria-label="Editar subcategoria"
        >
          <.icon name="hero-pencil" class="size-3" />
        </.link>
        <button
          id={"delete-category-#{@category.id}"}
          type="button"
          phx-click="confirm_delete"
          phx-value-id={@category.id}
          class="btn btn-ghost btn-xs px-1 text-error"
          title="Excluir subcategoria"
          aria-label="Excluir subcategoria"
        >
          <.icon name="hero-trash" class="size-3" />
        </button>
      </div>
    </div>
    """
  end

  defp type_label("fixed"), do: "Custo Fixo"
  defp type_label(_type), do: "Gasto Variável"

  defp subcategories_label([]), do: "Nenhuma subcategoria associada"
  defp subcategories_label([_one]), do: "Uma subcategoria associada"
  defp subcategories_label(children), do: "#{length(children)} subcategorias associadas"

  defp keyword_list(%Category{keywords: nil}), do: []

  defp keyword_list(%Category{keywords: keywords}) do
    keywords
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp category_emoji(%Category{name: name}) do
    normalized = String.downcase(name)

    Enum.find_value(@emojis, "📁", fn {terms, emoji} ->
      if Enum.any?(terms, &String.contains?(normalized, &1)), do: emoji
    end)
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Categorias")
     |> assign(:type_tabs, @type_tabs)
     |> assign(:fixo_hint, FormComponent.fixo_hint())
     |> assign(:confirm_modal, nil)
     |> assign(:type_filter, "all")
     |> assign(:search, "")
     |> assign(:collapsed_groups, MapSet.new())
     |> assign(:form_action, nil)
     |> assign(:form_category, nil)
     |> assign(:form_parent_id, nil)
     |> load_categories()
     |> assign_tree()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    socket
    |> assign(:page_title, "Nova Categoria")
    |> assign(:form_action, :new)
    |> assign(:form_category, %Category{default_reimbursable: false})
    |> assign(:form_parent_id, params["parent_id"])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Editar Categoria")
    |> assign(:form_action, :edit)
    |> assign(:form_category, Categories.get_category!(id))
    |> assign(:form_parent_id, nil)
  end

  defp apply_action(socket, _index, _params) do
    socket
    |> assign(:page_title, "Categorias")
    |> assign(:form_action, nil)
    |> assign(:form_category, nil)
    |> assign(:form_parent_id, nil)
  end

  defp load_categories(socket) do
    assign(socket, :categories, Categories.list_categories())
  end

  # The tree is derived on every render pass from the loaded list plus the
  # current filters, so filtering never needs a new database round-trip.
  defp build_tree(socket) do
    %{type_filter: type_filter, search: search, categories: categories} = socket.assigns
    search = search |> to_string() |> String.trim() |> String.downcase()

    categories
    |> Categories.group_by_parent()
    |> Enum.flat_map(fn {root, children} -> filter_group(root, children, type_filter, search) end)
  end

  # The type tab is a hard filter on every row, so a fixed root never lists its
  # variable subcategories. The search is scoped to the group instead: a root
  # matching the term shows all of its (type-matching) subcategories, since the
  # group as a whole is what the user searched for.
  defp filter_group(root, children, type_filter, search) do
    of_type = Enum.filter(children, &matches_type?(&1, type_filter))
    matching_children = Enum.filter(of_type, &matches_search?(&1, search))

    cond do
      matches?(root, type_filter, search) -> [{root, of_type}]
      matching_children != [] -> [{root, matching_children}]
      true -> []
    end
  end

  defp matches?(category, type_filter, search),
    do: matches_type?(category, type_filter) and matches_search?(category, search)

  defp matches_type?(_category, "all"), do: true
  defp matches_type?(category, "reimbursable"), do: category.default_reimbursable
  defp matches_type?(category, type), do: category.type == type

  defp matches_search?(_category, ""), do: true

  defp matches_search?(category, search) do
    haystack = String.downcase("#{category.name} #{category.keywords}")

    String.contains?(haystack, search)
  end

  defp assign_tree(socket), do: assign(socket, :tree, build_tree(socket))

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:type_filter, type) |> assign_tree()}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> assign_tree()}
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    collapsed = socket.assigns.collapsed_groups

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, :collapsed_groups, collapsed)}
  end

  def handle_event("expand_all", _params, socket) do
    {:noreply, assign(socket, :collapsed_groups, MapSet.new())}
  end

  def handle_event("collapse_all", _params, socket) do
    collapsed =
      socket.assigns.categories
      |> Enum.filter(&is_nil(&1.parent_id))
      |> MapSet.new(& &1.id)

    {:noreply, assign(socket, :collapsed_groups, collapsed)}
  end

  def handle_event("toggle_fixed", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    new_type = if category.type == "fixed", do: "variable", else: "fixed"

    case Categories.update_category(category, %{type: new_type}) do
      {:ok, _updated} ->
        {:noreply, socket |> load_categories() |> assign_tree()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Falha ao atualizar.")}
    end
  end

  # Whether the target still has subcategories is decided here, before anything
  # is deleted, so the modal can state the reason and disable its confirm
  # button instead of letting the delete fail against the database constraint.
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    has_children = Enum.any?(socket.assigns.categories, &(&1.parent_id == category.id))

    confirm = %{
      id: category.id,
      name: category.name,
      has_children: has_children,
      body: confirm_body(category.name, has_children)
    }

    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  def handle_event("close_modal", _params, socket),
    do: {:noreply, assign(socket, :confirm_modal, nil)}

  def handle_event("close_form_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/categories")}

  def handle_event("delete", %{"id" => id}, socket) do
    category = Categories.get_category!(id)

    case Categories.delete_category(category) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm_modal, nil)
         |> load_categories()
         |> assign_tree()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:confirm_modal, nil)
         |> put_flash(
           :error,
           "Não foi possível excluir a categoria '#{category.name}'. Verifique se há dependências."
         )}
    end
  end

  defp confirm_body(name, true),
    do:
      "A categoria \"#{name}\" possui subcategorias. Reatribua ou exclua as subcategorias antes de excluir esta categoria."

  defp confirm_body(name, false),
    do: "Esta ação não pode ser desfeita. Excluir \"#{name}\" permanentemente?"

  @impl true
  def handle_info({:category_saved, _category, action}, socket) do
    {:noreply,
     socket
     |> put_flash(:success, saved_flash(action))
     |> load_categories()
     |> assign_tree()
     |> push_patch(to: ~p"/categories")}
  end

  defp saved_flash(:new), do: "Categoria criada com sucesso!"
  defp saved_flash(:edit), do: "Categoria atualizada!"
end
