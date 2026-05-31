defmodule CashLensWeb.CategoryLive.Form do
  use CashLensWeb, :live_view

  alias CashLens.Categories
  alias CashLens.Categories.Category

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8">
      <.header>
        {@page_title}
        <:subtitle>Organize sua hierarquia financeira e defina regras de identificação.</:subtitle>
      </.header>

      <.form
        :let={f}
        for={@form}
        id="category-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-8 mt-8"
      >
        <div class="space-y-6 bg-base-100 p-8 rounded-3xl border border-base-300 shadow-sm">
          <div class="grid grid-cols-1 gap-6">
            <.input
              field={f[:name]}
              type="text"
              label="Nome da Categoria"
              placeholder="Ex: Moradia, Netflix..."
              required
            />
          </div>

          <div class="divider">Hierarquia</div>

          <div class="form-control w-full">
            <label class="label pb-1">
              <span class="label-text text-sm font-semibold">Categoria Pai (Opcional)</span>
            </label>
            <input
              type="hidden"
              id="parent_id_input"
              name="category[parent_id]"
              value={Phoenix.HTML.Form.input_value(f, :parent_id) || ""}
            />
            <div
              id="parent-category-autocomplete"
              phx-hook="CategoryAutocomplete"
              phx-update="ignore"
              data-target="#parent_id_input"
              data-categories={
                Jason.encode!(
                  Enum.map(
                    @parent_options,
                    &%{id: &1.id, name: CashLens.Categories.Category.full_name(&1)}
                  )
                )
              }
              class="relative w-full overflow-visible"
            >
              <input
                type="text"
                placeholder={
                  if @current_parent,
                    do: CashLens.Categories.Category.full_name(@current_parent),
                    else: "Nenhuma (Categoria Principal)"
                }
                class="input input-bordered w-full font-bold uppercase text-[10px] cursor-pointer"
              />
              <div class="dropdown-content hidden fixed z-[100] mt-1 w-64 bg-base-100 border border-base-300 rounded-xl shadow-2xl overflow-hidden max-h-60 overflow-y-auto">
                <ul class="menu menu-compact p-1">
                  <li class="new-option border-b border-base-200 mb-1">
                    <button type="button" class="font-black text-primary hover:bg-primary/10">
                      <.icon name="hero-plus-circle" class="size-4" />
                      <span>Nova Categoria</span>
                    </button>
                  </li>
                </ul>
              </div>
            </div>
            <button
              :if={@current_parent}
              type="button"
              phx-click="clear_parent"
              class="btn btn-ghost btn-xs text-error mt-1 self-start"
            >
              <.icon name="hero-x-mark" class="size-3 mr-1" /> Limpar pai
            </button>
          </div>

          <div class="divider">Configurações</div>

          <.input
            field={f[:type]}
            type="select"
            label="Tipo de Gasto"
            options={[
              {"Fixo (Contas Essenciais)", "fixed"},
              {"Variável (Estilo de Vida)", "variable"}
            ]}
          />

          <.input
            field={f[:default_reimbursable]}
            type="checkbox"
            label="Marcar automaticamente para reembolso?"
          />
          <p class="text-[10px] opacity-50 px-1 -mt-4 mb-4">
            Transações nesta categoria serão criadas com status de reembolso "Pendente".
          </p>

          <.input
            field={f[:keywords]}
            type="textarea"
            label="Palavras-chave (separadas por vírgula)"
            placeholder="Ex: UBER, 99APP, TAXI..."
            rows="3"
          />
          <p class="text-[10px] opacity-50 italic">
            Sempre que uma transação contiver uma dessas palavras, será automaticamente categorizada aqui.
          </p>
        </div>

        <div class="flex flex-col gap-3">
          <.button
            phx-disable-with="Salvando..."
            class="w-full btn-primary btn-lg shadow-xl shadow-primary/20 rounded-2xl"
          >
            <.icon name="hero-check-circle" class="size-5 mr-2" /> Salvar Categoria
          </.button>

          <.link navigate={~p"/categories"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-3 mr-1" /> Voltar à lista
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    all_categories =
      Categories.list_categories()
      |> Enum.sort_by(& &1.name)

    {:ok,
     socket
     |> assign(:parent_options, all_categories)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    category = Categories.get_category!(id)
    parents = Enum.reject(socket.assigns.parent_options, &(&1.id == id))
    current_parent = if category.parent_id, do: Enum.find(parents, &(&1.id == category.parent_id))

    socket
    |> assign(:page_title, "Editar Categoria")
    |> assign(:category, category)
    |> assign(:parent_options, parents)
    |> assign(:current_parent, current_parent)
    |> assign(:form, to_form(Categories.change_category(category)))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Nova Categoria")
    |> assign(:category, %Category{default_reimbursable: false})
    |> assign(:current_parent, nil)
    |> assign(:form, to_form(Categories.change_category(%Category{default_reimbursable: false})))
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset = Categories.change_category(socket.assigns.category, category_params)

    parent =
      if category_params["parent_id"] != "",
        do: Enum.find(socket.assigns.parent_options, &(&1.id == category_params["parent_id"]))

    {:noreply,
     socket
     |> assign(:current_parent, parent)
     |> assign(form: to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("clear_parent", _params, socket) do
    changeset = Categories.change_category(socket.assigns.category, %{"parent_id" => nil})

    {:noreply,
     socket |> assign(:current_parent, nil) |> assign(form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"category" => category_params}, socket) do
    save_category(socket, socket.assigns.live_action, category_params)
  end

  defp save_category(socket, :edit, category_params) do
    case Categories.update_category(socket.assigns.category, category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:success, "Categoria atualizada!")
         |> push_navigate(to: ~p"/categories")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_category(socket, :new, category_params) do
    case Categories.create_category(category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:success, "Categoria criada com sucesso!")
         |> push_navigate(to: ~p"/categories")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
