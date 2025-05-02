defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view

  import Phoenix.HTML.Form

  alias CashLens.Accounts
  alias CashLens.Accounts.Account

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
        current_user: session["current_user"],
        current_path: "/accounts",
        accounts: Accounts.list_accounts(),
        account_changeset: Accounts.change_account(%Account{}),
        editing_account: nil,
        show_form: false
      )
    }
  end

  def handle_event("new_account", _params, socket) do
    {:noreply,
     socket
     |> assign(
        account_changeset: Accounts.change_account(%Account{}),
        editing_account: nil,
        show_form: true
      )
    }
  end

  def handle_event("save", %{"account" => account_params}, socket) do
    if socket.assigns.editing_account do
      update_account(socket, socket.assigns.editing_account, account_params)
    else
      create_account(socket, account_params)
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:noreply,
     socket
     |> assign(
        account_changeset: Accounts.change_account(account),
        editing_account: account,
        show_form: true
      )
    }
  end

  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)

    {:noreply,
     socket
     |> put_flash(:info, "Account deleted successfully.")
     |> assign(accounts: Accounts.list_accounts())
    }
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, show_form: false)}
  end

  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset =
      (socket.assigns.editing_account || %Account{})
      |> Accounts.change_account(account_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, account_changeset: changeset)}
  end

  defp create_account(socket, account_params) do
    case Accounts.create_account(account_params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully.")
         |> assign(
            accounts: Accounts.list_accounts(),
            show_form: false
          )
        }

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, account_changeset: changeset)}
    end
  end

  defp update_account(socket, account, account_params) do
    case Accounts.update_account(account, account_params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully.")
         |> assign(
            accounts: Accounts.list_accounts(),
            editing_account: nil,
            show_form: false
          )
        }

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, account_changeset: changeset)}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-semibold text-gray-900">Accounts</h1>

      <div class="bg-white shadow sm:rounded-lg">
        <div class="px-4 py-5 sm:p-6">
          <div class="flex justify-between items-center">
            <h3 class="text-lg font-medium leading-6 text-gray-900">Your Accounts</h3>
            <button
              phx-click="new_account"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
            >
              New Account
            </button>
          </div>

          <%= if @show_form do %>
            <div class="mt-5">
              <.form
                :let={f}
                for={@account_changeset}
                id="account-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-4"
              >
                <div>
                  <.input field={f[:name]} type="text" label="Name" class="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm" />
                </div>

                <div>
                  <.input field={f[:bank_name]} type="text" label="Bank Name" class="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm" />
                </div>

                <div>
                  <.input field={f[:type]} type="select" label="Type" options={[{"Checking", :checking}, {"Credit Card", :credit_card}, {"Investment", :investment}]} class="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm" />
                </div>

                <div class="flex space-x-2">
                  <.button type="submit" class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500">Save</.button>
                  <button
                    type="button"
                    phx-click="cancel"
                    class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md shadow-sm text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </div>
          <% end %>

          <div class="mt-5">
            <%= if Enum.empty?(@accounts) do %>
              <p class="text-sm text-gray-500">No accounts yet. Create one to get started.</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-gray-200">
                  <thead class="bg-gray-50">
                    <tr>
                      <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
                      <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Bank</th>
                      <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Type</th>
                      <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
                    </tr>
                  </thead>
                  <tbody class="bg-white divide-y divide-gray-200">
                    <%= for account <- @accounts do %>
                      <tr>
                        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500"><%= account.name %></td>
                        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500"><%= account.bank_name %></td>
                        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500"><%= format_account_type(account.type) %></td>
                        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          <div class="flex space-x-2">
                            <button
                              phx-click="edit"
                              phx-value-id={account.id}
                              class="text-indigo-600 hover:text-indigo-900"
                            >
                              Edit
                            </button>
                            <button
                              phx-click="delete"
                              phx-value-id={account.id}
                              data-confirm="Are you sure you want to delete this account?"
                              class="text-red-600 hover:text-red-900"
                            >
                              Delete
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_account_type(:checking), do: "Checking"
  defp format_account_type(:credit_card), do: "Credit Card"
  defp format_account_type(:investment), do: "Investment"
  defp format_account_type(_), do: "Unknown"
end
