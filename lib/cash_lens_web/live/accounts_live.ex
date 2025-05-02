defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Accounts.Account
  alias CashLens.Parsers

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_user: session["current_user"],
       current_path: "/accounts",
       accounts: Accounts.list_accounts(),
       account_changeset: Accounts.change_account(%Account{}),
       editing_account: nil,
       show_form: false,
       available_parsers: Parsers.available_parsers(),
       available_types: Accounts.available_types()
     )}
  end

  def handle_event("new_account", _params, socket) do
    {:noreply,
     socket
     |> assign(
       account_changeset: Accounts.change_account(%Account{}),
       editing_account: nil,
       show_form: true
     )}
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
     )}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)

    {:noreply,
     socket
     |> put_flash(:info, "Account deleted successfully.")
     |> assign(accounts: Accounts.list_accounts())}
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
         )}

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
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, account_changeset: changeset)}
    end
  end

  def render(assigns) do
    CashLensWeb.AccountsLiveHTML.accounts(assigns)
  end
end
