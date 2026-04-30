defmodule CashLensWeb.TransactionLive.QuickCategoryComponent do
  use CashLensWeb, :live_component

  alias CashLens.Categories

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
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            New Category
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Create a new category to organize your entries.
          </p>

          <.form
            :let={f}
            for={@category_form}
            id="quick-category-form"
            phx-submit="save_quick_category"
            phx-target={@myself}
            class="space-y-6"
          >
            <.input
              field={f[:name]}
              type="text"
              label="Category Name"
              placeholder="e.g. Food, Leisure..."
              required
            />

            <div class="form-control w-full">
              <label class="label">
                <span class="label-text font-bold">Parent Category (Optional)</span>
              </label>
              <select name="parent_id" class="select select-bordered w-full rounded-2xl h-12">
                <option value="">None (Main Category)</option>
                <%= for cat <- Enum.filter(@categories, &is_nil(&1.parent_id)) do %>
                  <option value={cat.id}>{cat.name}</option>
                <% end %>
              </select>
            </div>

            <div class="pt-2">
              <button
                type="submit"
                class="btn btn-primary btn-lg w-full rounded-2xl shadow-lg shadow-primary/20"
                phx-disable-with="Creating..."
              >
                Save Category
              </button>
            </div>
          </.form>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def handle_event("save_quick_category", %{"name" => name, "parent_id" => parent_id}, socket) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")
    parent_id = if parent_id == "", do: nil, else: parent_id

    case Categories.create_category(%{name: name, slug: slug, parent_id: parent_id}) do
      {:ok, category} ->
        send(self(), {:category_created, category, socket.assigns.target_transaction_id})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Error creating category.")}
    end
  end
end
