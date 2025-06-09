defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view
  import CashLensWeb.BaseLive
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  alias CashLens.Accounts
  alias CashLens.Accounts.Account
  alias CashLens.Parsers
  alias CashLens.Utils

  def render(assigns) do
    ~H"""
      <.crud {assigns} target={Account} formatter={
        %{
          parser: &Parsers.format_parser/1,
          type: &Utils.capitalize/1
        }
      }/>
    """
  end
#  def handle_event("new_account", _params, socket) do
#    {:noreply,
#     socket
#     |> assign(
#       account_changeset: Accounts.change_account(%Account{}),
#       editing_account: nil,
#       show_form: true
#     )}
#  end

#  def handle_event("save", %{"account" => account_params}, socket) do
#    current_user = socket.assigns.current_user
#    IO.puts("save")
#
#    account_params =
#      account_params
#      |> Map.put("user_id", current_user.id)
#
#    if socket.assigns.editing_account do
#      {:noreply, socket}
#      update_account(socket, socket.assigns.editing_account, account_params)
#    else
#      case Accounts.create_account(account_params) do
#        {:ok, _account} ->
#          {:noreply,
#           socket
#           |> put_flash(:info, "Account created successfully.")
#           |> assign(
#             accounts: Accounts.list_accounts(current_user),
#             show_form: false
#           )}

          #
          #      {:error, %Ecto.Changeset{} = changeset} ->
          #      errors = changeset.errors
          #      |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
          #      |> Enum.join(" - ")
          #        {:noreply,
          #         socket
          #         |> put_flash(:error, errors)
          #         |> assign(account_changeset: changeset)}
#      end
#    end
#  end

#    def handle_event("edit", %{"id" => id}, socket) do
#      account = Accounts.get_account!(id)
#
#      {:noreply,
#       socket
#       |> assign(
#         account_changeset: Accounts.change_account(account),
#         editing_account: account,
#         show_form: true
#       )}
#    end
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
#  def handle_event("validate", %{"account" => account_params}, socket) do
#    changeset =
#      (socket.assigns.editing_account || %Account{})
#      |> Accounts.change_account(account_params)
#      |> Map.put(:action, :validate)
#
#    {:noreply, assign(socket, account_changeset: changeset)}
#  end

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

end
