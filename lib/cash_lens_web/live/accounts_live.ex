defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  alias CashLens.Accounts
  alias CashLens.Accounts.Account
  alias CashLens.Parsers
  alias CashLens.Utils

  def mount(_params, %{"current_user" => current_user} = _session, socket) do
    {:ok,
     socket
     |> assign(
       accounts: Accounts.list_accounts(current_user.id),
       account_changeset: Accounts.change_account(%Account{}),
       editing_account: nil,
       show_form: false,
       available_parsers: Parsers.available_parsers_options(),
       available_types: Utils.to_options(Account.available_types())
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
    current_user = socket.assigns.current_user

    account_params =
      account_params
      |> Map.put("user_id", current_user.id)

    if socket.assigns.editing_account do
      account_params
#      update_account(socket, socket.assigns.editing_account, account_params)
    else
      case Accounts.create_account(account_params) do
        {:ok, _account} ->
          {:noreply,
           socket
           |> put_flash(:info, "Account created successfully.")
           |> assign(
             accounts: Accounts.list_accounts(),
             show_form: false
           )}

          #
          #      {:error, %Ecto.Changeset{} = changeset} ->
          #      errors = changeset.errors
          #      |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
          #      |> Enum.join(" - ")
          #        {:noreply,
          #         socket
          #         |> put_flash(:error, errors)
          #         |> assign(account_changeset: changeset)}
      end
    end
  end

  #  def handle_event("edit", %{"id" => id}, socket) do
  #    account = Accounts.get_account!(id)
  #
  #    {:noreply,
  #     socket
  #     |> assign(
  #       account_changeset: Accounts.change_account(account),
  #       editing_account: account,
  #       show_form: true
  #     )}
  #  end
  #
  #  def handle_event("delete", %{"id" => id}, socket) do
  #    account = Accounts.get_account!(id)
  #    {:ok, _} = Accounts.delete_account(account)
  #
  #    {:noreply,
  #     socket
  #     |> put_flash(:info, "Account deleted successfully.")
  #     |> assign(accounts: Accounts.list_accounts())}
  #  end
  #
  #  def handle_event("cancel", _params, socket) do
  #    {:noreply, assign(socket, show_form: false)}
  #  end
  #
  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset =
      (socket.assigns.editing_account || %Account{})
      |> Accounts.change_account(account_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, account_changeset: changeset)}
  end

  #  defp update_account(socket, account, account_params) do
  #    case Accounts.update_account(account, account_params) do
  #      {:ok, _account} ->
  #        {:noreply,
  #         socket
  #         |> put_flash(:info, "Account updated successfully.")
  #         |> assign(
  #           accounts: Accounts.list_accounts(),
  #           editing_account: nil,
  #           show_form: false
  #         )}
  #
  #      {:error, %Ecto.Changeset{} = changeset} ->
  #        {:noreply, assign(socket, account_changeset: changeset)}
  #    end
  #  end

  def render(assigns) do
    CashLensWeb.AccountsLiveHTML.accounts(assigns)
  end
end
