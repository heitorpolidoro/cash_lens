defmodule CashLensWeb.AutomationLive.BulkIgnore do
  use CashLensWeb, :live_view
  alias CashLens.Transactions
  alias CashLens.Transactions.BulkIgnorePattern

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Exclusion Rules
        <:subtitle>
          Register patterns (Regex) for descriptions that should be ignored in bulk categorization suggestions.
        </:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <!-- Registration Form -->
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <h2 class="text-sm font-black uppercase opacity-50 mb-4">New Rule</h2>
              <.form
                for={@form}
                id="ignore-form"
                phx-submit="save"
                phx-change="validate"
                class="space-y-4"
              >
                <.input
                  field={@form[:pattern]}
                  type="text"
                  label="Pattern (Regex)"
                  placeholder="e.g. ^PIX SENT"
                  required
                />
                <.input
                  field={@form[:description]}
                  type="text"
                  label="Reason"
                  placeholder="e.g. Generic transactions"
                />
                <div class="pt-2">
                  <button
                    type="submit"
                    class="btn btn-primary w-full rounded-xl"
                    phx-disable-with="Saving..."
                  >
                    Save Rule
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
        
    <!-- Pattern List -->
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
            <div class="card-body p-0">
              <table class="table table-zebra w-full text-xs">
                <thead class="bg-base-200/50">
                  <tr>
                    <th>Pattern</th>
                    <th>Reason</th>
                    <th class="w-16"></th>
                  </tr>
                </thead>
                <tbody id="patterns" phx-update="stream">
                  <tr :for={{id, pattern} <- @streams.patterns} id={id} class="hover group">
                    <td class="font-mono font-bold text-primary">{pattern.pattern}</td>
                    <td class="opacity-60">{pattern.description}</td>
                    <td class="text-right pr-4">
                      <button
                        phx-click="delete"
                        phx-value-id={pattern.id}
                        data-confirm="Are you sure you want to delete this pattern?"
                        class="btn btn-ghost btn-xs text-error opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div id="no-patterns-msg" class="p-10 text-center opacity-30 italic only:block hidden">
                No patterns registered.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    patterns = Transactions.list_bulk_ignore_patterns()

    {:ok,
     socket
     |> assign(:form, to_form(Transactions.change_bulk_ignore_pattern(%BulkIgnorePattern{})))
     |> stream(:patterns, patterns)}
  end

  @impl true
  def handle_event("validate", %{"bulk_ignore_pattern" => params}, socket) do
    form =
      %BulkIgnorePattern{}
      |> Transactions.change_bulk_ignore_pattern(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("save", %{"bulk_ignore_pattern" => params}, socket) do
    case Transactions.create_bulk_ignore_pattern(params) do
      {:ok, pattern} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pattern registered!")
         |> stream_insert(:patterns, pattern)
         |> assign(:form, to_form(Transactions.change_bulk_ignore_pattern(%BulkIgnorePattern{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    pattern = Transactions.get_bulk_ignore_pattern!(id)
    {:ok, _} = Transactions.delete_bulk_ignore_pattern(pattern)

    {:noreply,
     socket |> stream_delete(:patterns, pattern) |> put_flash(:info, "Pattern removed.")}
  end
end
