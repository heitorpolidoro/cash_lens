defmodule CashLensWeb.CategoryLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Categories
        <:actions>
          <.link navigate={~p"/categories/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> New Category
            </.button>
          </.link>
        </:actions>
      </.header>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th class="text-center">Reimbursement?</th>
              <th>Keywords (Rules)</th>
              <th class="w-16"></th>
            </tr>
          </thead>
          <tbody id="categories" phx-update="stream">
            <tr
              :for={{id, category} <- @streams.categories}
              id={id}
              class="hover group border-b border-base-200"
            >
              <td class="font-bold">{CashLens.Categories.Category.full_name(category)}</td>
              <td>
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-secondary checkbox-xs"
                    checked={category.type == "fixed"}
                    phx-click="toggle_fixed"
                    phx-value-id={category.id}
                  />
                  <span class="text-[9px] font-black uppercase opacity-60">Fixed</span>
                </label>
              </td>
              <td class="text-center">
                <%= if category.default_reimbursable do %>
                  <span title="Generates automatic reimbursement">
                    <.icon name="hero-banknotes" class="size-5 text-primary mx-auto" />
                  </span>
                <% else %>
                  <span class="opacity-10">—</span>
                <% end %>
              </td>
              <td class="max-w-xs truncate italic opacity-60">{category.keywords}</td>
              <td class="text-right">
                <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity pr-4">
                  <.link
                    navigate={~p"/categories/#{category}/edit"}
                    class="btn btn-ghost btn-xs px-1"
                    phx-click-stop
                  >
                    <.icon name="hero-pencil" class="size-3" />
                  </.link>
                  <button
                    type="button"
                    phx-click="confirm_delete"
                    phx-value-id={category.id}
                    phx-click-stop
                    class="btn btn-ghost btn-xs text-error px-1"
                  >
                    <.icon name="hero-trash" class="size-3" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Confirmation Modal -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Delete Category?</h2>
        <p class="text-base-content/60 mb-10">Do you really want to delete this category?</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">
            Yes, Delete
          </button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Categories")
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

    case Categories.delete_category(category) do
      {:ok, _} ->
        {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:categories, category)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:confirm_modal, nil)
         |> put_flash(
           :error,
           "Could not delete category '#{category.name}'. Check if there are dependencies."
         )}
    end
  end

  @impl true
  def handle_event("toggle_fixed", %{"id" => id}, socket) do
    category = Categories.get_category!(id)
    new_type = if category.type == "fixed", do: "variable", else: "fixed"

    case Categories.update_category(category, %{type: new_type}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :categories, updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update.")}
    end
  end
end
