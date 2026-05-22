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
            New Category
            <:subtitle>Organize your financial hierarchy and define identification rules.</:subtitle>
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
              label="Category Name"
              placeholder="Ex: Housing, Netflix..."
              required
            />

            <div class="divider">Hierarchy</div>

            <div class="form-control w-full">
              <label class="label pb-1">
                <span class="label-text text-sm font-semibold">Parent Category (Optional)</span>
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
                      else: "None (Main Category)"
                  }
                  class="input input-bordered w-full font-bold uppercase text-[10px] cursor-pointer"
                />
                <div class="dropdown-content hidden fixed z-[100] mt-1 w-64 bg-base-100 border border-base-300 rounded-xl shadow-2xl overflow-hidden max-h-60 overflow-y-auto">
                  <ul class="menu menu-compact p-1">
                    <li class="new-option border-b border-base-200 mb-1">
                      <button type="button" class="font-black text-primary hover:bg-primary/10">
                        <.icon name="hero-plus-circle" class="size-4" />
                        <span>New Category</span>
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
                <.icon name="hero-x-mark" class="size-3 mr-1" /> Clear parent
              </button>
            </div>

            <div class="divider">Settings</div>

            <.input
              field={f[:type]}
              type="select"
              label="Spending Type"
              options={[
                {"Fixed (Essential Bills)", "fixed"},
                {"Variable (Lifestyle)", "variable"}
              ]}
            />

            <.input
              field={f[:default_reimbursable]}
              type="checkbox"
              label="Mark automatically for reimbursement?"
            />
            <p class="text-[10px] opacity-50 px-1 -mt-4 mb-4">
              Transactions in this category will be created with "Pending" reimbursement status.
            </p>

            <.input
              field={f[:keywords]}
              type="textarea"
              label="Keywords (Comma separated)"
              placeholder="Ex: UBER, 99APP, TAXI..."
              rows="3"
            />
            <p class="text-[10px] opacity-50 italic">
              Whenever a transaction contains one of these words, it will be automatically categorized here.
            </p>

            <div class="pt-2">
              <.button
                type="submit"
                phx-disable-with="Creating..."
                class="w-full btn-primary btn-lg shadow-xl shadow-primary/20 rounded-2xl"
              >
                <.icon name="hero-check-circle" class="size-5 mr-2" /> Save Category
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
     |> assign(:parent_options, parent_options)}
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset = Categories.change_category(%Category{}, category_params)

    parent =
      if category_params["parent_id"] != "",
        do: Enum.find(socket.assigns.parent_options, &(&1.id == category_params["parent_id"]))

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
end
