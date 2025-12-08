defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Accounts.Account

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       accounts: Accounts.list_accounts(),
       form: to_form(%{}),
       editing: false
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, form: to_form(%{}), editing: nil)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Accounts.get_account(id) do
      {:ok, account} ->
        form_data = %{
          "id" => BSON.ObjectId.encode!(account._id),
          "bank" => account.bank,
          "name" => account.name,
          "type" => to_string(account.type)
        }

        {:noreply, assign(socket, form: to_form(form_data), editing: id)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"bank" => bank, "name" => name, "type" => type}, socket) do
    attrs = %{
      bank: bank,
      name: name,
      type: String.to_atom(type)
    }

    result =
      if socket.assigns[:editing] do
        Accounts.update_account(socket.assigns.editing, attrs)
      else
        Accounts.create_account(attrs)
      end

    case result do
      {:ok, _account} ->
        {:noreply, assign(socket, accounts: Accounts.list_accounts(), form: to_form(%{}), editing: nil)}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to save account")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Accounts.delete_account(id)
    {:noreply, assign(socket, accounts: Accounts.list_accounts())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto">
      <h1 class="text-3xl font-bold mb-6">Accounts</h1>

      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-xl font-semibold mb-4">{if @editing, do: "Edit Account", else: "New Account"}</h2>
        <.form for={@form} phx-submit="save" class="space-y-4">
          <div>
            <label class="block text-sm font-medium mb-1">Bank</label>
            <input type="text" name="bank" value={@form[:bank].value} required class="w-full px-3 py-2 border rounded" />
          </div>
          <div>
            <label class="block text-sm font-medium mb-1">Name</label>
            <input type="text" name="name" value={@form[:name].value} required class="w-full px-3 py-2 border rounded" />
          </div>
          <div>
            <label class="block text-sm font-medium mb-1">Type</label>
            <select name="type" required class="w-full px-3 py-2 border rounded">
              <option value="">Select type</option>
              <option value="checking" selected={@form[:type].value == "checking"}>Checking</option>
              <option value="credit_card" selected={@form[:type].value == "credit_card"}>Credit Card</option>
              <option value="investment" selected={@form[:type].value == "investment"}>Investment</option>
              <option value="savings" selected={@form[:type].value == "savings"}>Savings</option>
            </select>
          </div>
          <div class="flex gap-2">
            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              {if @editing, do: "Update", else: "Create"}
            </button>
            <button type="button" phx-click="new" class="px-4 py-2 bg-gray-300 rounded hover:bg-gray-400">
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Bank</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Type</th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for account <- @accounts do %>
              <tr>
                <td class="px-6 py-4 whitespace-nowrap">{account.bank}</td>
                <td class="px-6 py-4 whitespace-nowrap">{account.name}</td>
                <td class="px-6 py-4 whitespace-nowrap">{account.type}</td>
                <td class="px-6 py-4 whitespace-nowrap text-right">
                  <button
                    phx-click="edit"
                    phx-value-id={BSON.ObjectId.encode!(account._id)}
                    class="text-blue-600 hover:text-blue-900 mr-3"
                  >
                    Edit
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={BSON.ObjectId.encode!(account._id)}
                    class="text-red-600 hover:text-red-900"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
