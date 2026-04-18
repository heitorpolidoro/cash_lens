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

          <.input
            field={f[:parent_id]}
            type="select"
            label="Categoria Pai (Opcional)"
            options={Enum.map(@parent_options, &{CashLens.Categories.Category.full_name(&1), &1.id})}
            prompt="Nenhuma (Categoria Principal)"
          />

          <div class="divider">Configurações</div>

          <.input
            field={f[:type]}
            type="select"
            label="Tipo de Gasto"
            options={[
              {"Fixo (Contas Obrigatórias)", "fixed"},
              {"Variável (Estilo de Vida)", "variable"}
            ]}
          />

          <.input
            field={f[:default_reimbursable]}
            type="checkbox"
            label="Marcar automaticamente para reembolso?"
          />
          <p class="text-[10px] opacity-50 px-1 -mt-4 mb-4">
            Transações desta categoria nascerão com status "Pendente" de reembolso.
          </p>

          <.input
            field={f[:keywords]}
            type="textarea"
            label="Palavras-chave (Separadas por vírgula)"
            placeholder="Ex: UBER, 99APP, TAXI..."
            rows="3"
          />
          <p class="text-[10px] opacity-50 italic">
            Sempre que uma transação contiver uma dessas palavras, ela será categorizada automaticamente aqui.
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
            <.icon name="hero-arrow-left" class="size-3 mr-1" /> Voltar para lista
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
    # Filter out current category from parents to avoid self-reference
    parents = Enum.reject(socket.assigns.parent_options, &(&1.id == id))

    socket
    |> assign(:page_title, "Editar Categoria")
    |> assign(:category, category)
    |> assign(:parent_options, parents)
    |> assign(:form, to_form(Categories.change_category(category)))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Nova Categoria")
    |> assign(:category, %Category{default_reimbursable: false})
    |> assign(:form, to_form(Categories.change_category(%Category{default_reimbursable: false})))
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    # Auto-generate slug from name if empty
    params = maybe_generate_slug(category_params)
    changeset = Categories.change_category(socket.assigns.category, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"category" => category_params}, socket) do
    save_category(socket, socket.assigns.live_action, category_params)
  end

  defp save_category(socket, :edit, category_params) do
    case Categories.update_category(socket.assigns.category, category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Categoria atualizada!")
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
         |> put_flash(:info, "Categoria criada com sucesso!")
         |> push_navigate(to: ~p"/categories")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp maybe_generate_slug(%{"name" => name, "slug" => ""} = params) when name != "" do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")
    Map.put(params, "slug", slug)
  end

  defp maybe_generate_slug(params), do: params
end
