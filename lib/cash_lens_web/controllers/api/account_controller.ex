defmodule CashLensWeb.Api.AccountController do
  use CashLensWeb, :controller

  alias CashLens.Accounts

  def index(conn, _params) do
    accounts = Accounts.list_accounts()
    json(conn, %{data: Enum.map(accounts, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    account = Accounts.get_account!(id)
    json(conn, %{data: serialize(account)})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, params) do
    case Accounts.create_account(params) do
      {:ok, account} ->
        conn |> put_status(201) |> json(%{data: serialize(account)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    account = Accounts.get_account!(id)

    case Accounts.update_account(account, params) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{"id" => id}) do
    account = Accounts.get_account!(id)

    case Accounts.delete_account(account) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp serialize(a) do
    %{
      id: a.id,
      name: a.name,
      bank: a.bank,
      balance: a.balance,
      color: a.color,
      icon: a.icon,
      parser_type: a.parser_type,
      accepts_import: a.accepts_import,
      is_closed: a.is_closed,
      is_credit_card: a.is_credit_card
    }
  end

  defp not_found(conn), do: send_resp(conn, 404, ~s({"error":"not found"}))

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
