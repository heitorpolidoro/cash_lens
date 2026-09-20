defmodule CashLensWeb.CategoryLive.FormComponent do
  @moduledoc """
  The category form, rendered as a modal overlaid on `/categories` for both
  `/categories/new` and `/categories/:id/edit` (CL-16).

  The parent selector is a plain select: it lists every other category by its
  full hierarchical name, minus the category being edited and its own
  descendants, so a cycle cannot be created from the UI. `/categories/new` also
  accepts a `parent_id` query parameter, which is how the "+ Subcategoria"
  action on a root card opens the form with the parent already chosen.
  """

  use CashLensWeb, :live_component

  alias CashLens.Categories

  @fixo_hint "Fixo (Contas Essenciais): entra na previsão de caixa em /forecast como compromisso recorrente."

  @doc """
  The inline explanation of what the "Fixo" type does, shared with the tree so
  both places state the same thing.
  """
  def fixo_hint, do: @fixo_hint

  @impl true
  def update(%{category: category, action: action} = assigns, socket) do
    # The pre-selected parent is written straight onto the struct rather than
    # passed as changeset params: at this point the name is still blank, and a
    # `parent_id` *change* would make the slug generation run against it.
    category = with_preselected_parent(category, assigns)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:category, category)
     |> assign(:fixo_hint, @fixo_hint)
     |> assign(:parent_options, parent_options(category, action))
     |> assign(:form, to_form(Categories.change_category(category, %{})))}
  end

  defp with_preselected_parent(category, %{action: :new, parent_id: parent_id})
       when is_binary(parent_id),
       do: %{category | parent_id: parent_id}

  defp with_preselected_parent(category, _assigns), do: category

  # Only a root category may be chosen as the parent: the tree on `/categories`
  # is two levels deep, so offering a subcategory here would create a category
  # that is rendered nowhere and could no longer be edited or deleted. The
  # category's *current* parent is always kept as an option, even when it is
  # not a root, so editing a deeper category that predates this rule does not
  # silently promote it to a root. A category may also not become a child of
  # itself or of one of its own descendants.
  defp parent_options(category, action) do
    excluded = excluded_parent_ids(category, action)

    Categories.list_categories()
    |> Enum.filter(&selectable_parent?(&1, category, excluded))
    |> to_options()
  end

  defp excluded_parent_ids(category, :edit),
    do: MapSet.new(Categories.get_category_ids_with_children(category.id))

  defp excluded_parent_ids(_category, :new), do: MapSet.new()

  defp selectable_parent?(option, category, excluded) do
    not MapSet.member?(excluded, option.id) and
      (is_nil(option.parent_id) or option.id == category.parent_id)
  end

  defp to_options(categories) do
    categories
    |> Enum.map(&{Categories.Category.full_name(&1), &1.id})
    |> Enum.sort_by(fn {name, _id} -> name end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="category-form-modal"
      class="modal modal-open"
      phx-window-keydown="close_form_modal"
      phx-key="escape"
    >
      <div class="modal-box max-w-lg p-0 bg-base-100 border border-base-300 rounded-3xl shadow-2xl">
        <div class="px-6 py-5 border-b border-base-200 flex items-center justify-between">
          <div>
            <h3 class="text-base font-bold">{modal_title(@action)}</h3>
            <p class="text-xs text-base-content/50 mt-0.5">
              Defina o nome, relação hierárquica e palavras-chave.
            </p>
          </div>
          <button
            id="category-form-modal-close"
            type="button"
            phx-click="close_form_modal"
            class="btn btn-sm btn-circle btn-ghost"
            title="Fechar"
            aria-label="Fechar"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="category-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          class="px-6 py-5 max-h-[70vh] overflow-y-auto"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Nome da Categoria"
            placeholder="Ex: Farmácia & Remédios"
          />

          <.input
            field={@form[:parent_id]}
            type="select"
            label="Categoria Pai (Opcional para criar Subcategoria)"
            options={@parent_options}
            prompt="Nenhuma (Categoria Raiz)"
          />

          <.input
            field={@form[:type]}
            type="select"
            label="Tipo de Gasto"
            options={[
              {"Variável (Estilo de Vida)", "variable"},
              {"Fixo (Contas Essenciais)", "fixed"}
            ]}
          />
          <p id="category-form-fixo-hint" class="text-[11px] opacity-60 -mt-3 mb-4 px-1">
            {@fixo_hint}
          </p>

          <.input
            field={@form[:default_reimbursable]}
            type="checkbox"
            label="Reembolsável por Padrão?"
          />

          <.input
            field={@form[:keywords]}
            type="textarea"
            label="Palavras-chave de Reconhecimento Automático"
            placeholder="Separe por vírgulas. Ex: drogasil, drogaria, pacheco, farmacia"
            rows="2"
          />
          <p class="text-[11px] opacity-60 -mt-3 px-1">
            Ao importar extratos, transações que contenham esses termos serão automaticamente
            vinculadas a esta categoria.
          </p>

          <div class="flex items-center justify-end gap-2 pt-6">
            <button type="button" phx-click="close_form_modal" class="btn btn-ghost rounded-xl">
              Cancelar
            </button>
            <button type="submit" phx-disable-with="Salvando..." class="btn btn-primary rounded-xl">
              Salvar Categoria
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp modal_title(:edit), do: "Editar Categoria"
  defp modal_title(_action), do: "Nova Categoria"

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset = Categories.change_category(socket.assigns.category, category_params)

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"category" => category_params}, socket) do
    save_category(socket, socket.assigns.action, category_params)
  end

  defp save_category(socket, :edit, category_params) do
    case Categories.update_category(socket.assigns.category, category_params) do
      {:ok, category} ->
        send(self(), {:category_saved, category, :edit})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(surface_slug_error(changeset)))}
    end
  end

  defp save_category(socket, :new, category_params) do
    case Categories.create_category(category_params) do
      {:ok, category} ->
        send(self(), {:category_saved, category, :new})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(surface_slug_error(changeset)))}
    end
  end

  # A duplicate name trips the unique index on the generated `slug` before the
  # one on `name`, and `slug` is not a field of this form: the message is moved
  # onto the name field so the user actually sees why the save failed.
  defp surface_slug_error(%Ecto.Changeset{} = changeset) do
    case Keyword.pop_values(changeset.errors, :slug) do
      {[], _errors} ->
        changeset

      {slug_errors, other_errors} ->
        %{changeset | errors: Enum.map(slug_errors, &{:name, &1}) ++ other_errors}
    end
  end
end
