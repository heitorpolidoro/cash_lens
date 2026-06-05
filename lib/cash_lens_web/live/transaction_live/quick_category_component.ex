defmodule CashLensWeb.TransactionLive.QuickCategoryComponent do
  use CashLensWeb, :live_component

  alias CashLens.Categories
  alias CashLens.Categories.Category

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal
        :if={@show}
        id={"#{@id}-modal"}
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <.header>
            Nova Categoria
            <:subtitle>
              Organize sua hierarquia financeira e defina regras de identificação.
            </:subtitle>
          </.header>

          <.form
            :let={f}
            for={@category_form}
            id="quick-category-form"
            phx-change="validate"
            phx-submit="save_quick_category"
            phx-target={@myself}
            class="space-y-6 mt-6"
          >
            <.input
              field={f[:name]}
              type="text"
              label="Nome da Categoria"
              placeholder="Ex: Moradia, Netflix..."
              required
            />

            <div class="divider">Hierarquia</div>

            <div class="form-control w-full">
              <label class="label pb-1">
                <span class="label-text text-sm font-semibold">Categoria Pai (Opcional)</span>
              </label>
              <input
                type="hidden"
                id="quick_parent_id_input"
                name="category[parent_id]"
                value={Phoenix.HTML.Form.input_value(f, :parent_id) || ""}
              />
              <div
                id="quick-parent-category-autocomplete"
                phx-hook="CategoryAutocomplete"
                phx-update="ignore"
                data-target="#quick_parent_id_input"
                data-categories={
                  Jason.encode!(
                    Enum.map(@parent_options, &%{id: &1.id, name: Category.full_name(&1)})
                  )
                }
                class="relative w-full overflow-visible"
              >
                <input
                  type="text"
                  placeholder={
                    if @current_parent,
                      do: Category.full_name(@current_parent),
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
                phx-target={@myself}
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

            <div class="pt-2">
              <.button
                type="submit"
                phx-disable-with="Criando..."
                class="w-full btn-primary btn-lg shadow-xl shadow-primary/20 rounded-2xl"
              >
                <.icon name="hero-check-circle" class="size-5 mr-2" /> Salvar Categoria
              </.button>
            </div>
          </.form>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    parent_options = Enum.sort_by(assigns.categories, & &1.name)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:parent_options, parent_options)
     |> assign_new(:current_parent, fn -> nil end)}
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset = Categories.change_category(%Category{}, category_params)

    parent = find_parent_option(socket.assigns.parent_options, category_params["parent_id"])

    {:noreply,
     socket
     |> assign(:current_parent, parent)
     |> assign(:category_form, to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("clear_parent", _params, socket) do
    changeset = Categories.change_category(%Category{}, %{"parent_id" => nil})

    {:noreply,
     socket
     |> assign(:current_parent, nil)
     |> assign(:category_form, to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("save_quick_category", %{"category" => category_params}, socket) do
    case Categories.create_category(category_params) do
      {:ok, category} ->
        send(self(), {:category_created, category, socket.assigns.target_transaction_id})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :category_form, to_form(changeset))}
    end
  end

  defp find_parent_option(_options, parent_id) when parent_id in [nil, ""], do: nil
  defp find_parent_option(options, parent_id), do: Enum.find(options, &(&1.id == parent_id))
end
