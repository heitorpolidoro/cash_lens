defmodule CashLensWeb.AutomaticTransferController do
  use CashLensWeb, :controller

  alias CashLens.AutomaticTransfers
  alias CashLens.AutomaticTransfers.AutomaticTransfer
  alias CashLens.Accounts
  alias CashLens.Accounts.Account

  def index(conn, _params) do
    automatic_transfers = AutomaticTransfers.list_automatic_transfers()
    render(conn, :index, automatic_transfers: automatic_transfers)
  end

  def new(conn, _params) do
    changeset = AutomaticTransfers.change_automatic_transfer(%AutomaticTransfer{})
    accounts = Accounts.list_accounts_for_select() |> IO.inspect()
    render(conn, :new, changeset: changeset, accounts: accounts) |> IO.inspect()
  end

  def create(conn, %{"automatic_transfer" => automatic_transfer_params}) do
    case AutomaticTransfers.create_automatic_transfer(automatic_transfer_params) do
      {:ok, automatic_transfer} ->
        conn
        |> put_flash(:info, "AutomaticTransfer '#{to_str(automatic_transfer)}' created successfully.")
        |> redirect(to: ~p"/transfers/automatic_transfers")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset, accounts: nil)
    end
  end

  def show(conn, %{"id" => id}) do
    automatic_transfer = AutomaticTransfers.get_automatic_transfer!(id)
    render(conn, :show, automatic_transfer: automatic_transfer)
  end

  def edit(conn, %{"id" => id}) do
    automatic_transfer = AutomaticTransfers.get_automatic_transfer!(id)
    changeset = AutomaticTransfers.change_automatic_transfer(automatic_transfer)
    render(conn, :edit, automatic_transfer: automatic_transfer, changeset: changeset, accounts: nil)
  end

  def update(conn, %{"id" => id, "automatic_transfer" => automatic_transfer_params}) do
    automatic_transfer = AutomaticTransfers.get_automatic_transfer!(id)

    case AutomaticTransfers.update_automatic_transfer(automatic_transfer, automatic_transfer_params) do
      {:ok, automatic_transfer} ->
        conn
        |> put_flash(:info, "AutomaticTransfer '#{to_str(automatic_transfer)}' updated successfully.")
        |> redirect(to: ~p"/transfers/automatic_transfers")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, automatic_transfer: automatic_transfer, changeset: changeset, accounts: nil)
    end
  end

  def delete(conn, %{"id" => id}) do
    automatic_transfer = AutomaticTransfers.get_automatic_transfer!(id)
    {:ok, _automatic_transfer} = AutomaticTransfers.delete_automatic_transfer(automatic_transfer)

    conn
    |> put_flash(:info, "AutomaticTransfer '#{to_str(automatic_transfer)}' deleted successfully.")
    |> redirect(to: ~p"/transfers/automatic_transfers")
  end

  def to_str(automatic_transfer) do
    "AutomaticTransfer ##{automatic_transfer.id}"
#    "#{transfer.bank_name} - #{transfer.name}"
  end
end
