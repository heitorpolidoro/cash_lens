defmodule CashLensWeb.BalanceController do
  use CashLensWeb, :controller

  alias CashLens.Balances
  alias CashLens.Balances.Balance
  alias CashLens.Accounts

  def index(conn, _params) do
    balances = Balances.list_balances()
    render(conn, :index, balances: balances)
  end

  def show(conn, %{"id" => "recalculate"}) do
    Balances.recalculate_balances()
    redirect(conn, to: ~p"/balances")
  end

  def show(conn, %{"id" => id}) do
    balance = Balances.get_balance!(id)
    render(conn, :show, balance: balance)
  end

  def edit(conn, %{"id" => id}) do
    balance = Balances.get_balance!(id)
    accounts = Accounts.list_accounts_for_select()
    changeset = Balances.change_balance(balance)
    render(conn, :edit, balance: balance, changeset: changeset, accounts: accounts)
  end

  def update(conn, %{"id" => id, "balance" => balance_params}) do
    balance = Balances.get_balance!(id)

    case Balances.update_balance(balance, balance_params) do
      {:ok, balance} ->
        conn
        |> put_flash(:info, "Balance updated successfully.")
        |> redirect(to: ~p"/balances")

      {:error, %Ecto.Changeset{} = changeset} ->
        accounts = Accounts.list_accounts_for_select()
        render(conn, :edit, balance: balance, changeset: changeset, accounts: accounts)
    end
  end

  def delete(conn, %{"id" => id}) do
    balance = Balances.get_balance!(id)
    {:ok, _balance} = Balances.delete_balance(balance)

    conn
    #    |> put_flash(:info, "Balance '#{to_str(balance)}' deleted successfully.")
    |> redirect(to: ~p"/balances")
  end

  def recalculate(conn) do
    #    balance = Balances.get_balance!(id)
    #
    #    case Balances.recalculate_balance(balance) do
    #      {:ok, balance} ->
    #        conn
    #        |> put_flash(:info, "Balance recalculated successfully.")
    #        |> redirect(to: ~p"/balances/#{balance}")
    #
    #      {:error, %Ecto.Changeset{} = changeset} ->
    #        accounts = Accounts.list_accounts_for_select()
    #        render(conn, :edit, balance: balance, changeset: changeset, accounts: accounts)
    #    end
  end
end
