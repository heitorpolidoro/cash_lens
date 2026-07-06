defmodule CashLensWeb.Api.BalanceController do
  use CashLensWeb, :controller

  alias CashLens.Accounting

  # Supports: account_id, month, year, page, page_size
  def index(conn, params) do
    page = parse_int(params["page"], 1)
    page_size = params["page_size"] |> parse_int(20) |> min(200)
    filters = Map.take(params, ["account_id", "month", "year"])

    balances = Accounting.list_balances(filters, page, page_size)

    json(conn, %{
      data: Enum.map(balances, &serialize/1),
      meta: %{page: page, page_size: page_size}
    })
  end

  def show(conn, %{"id" => id}) do
    balance = Accounting.get_balance!(id)
    json(conn, %{data: serialize(balance)})
  rescue
    Ecto.NoResultsError -> send_resp(conn, 404, ~s({"error":"not found"}))
  end

  defp serialize(b) do
    %{
      id: b.id,
      year: b.year,
      month: b.month,
      initial_balance: b.initial_balance,
      income: b.income,
      expenses: b.expenses,
      transfers_in: b.transfers_in,
      transfers_out: b.transfers_out,
      balance: b.balance,
      final_balance: b.final_balance,
      is_snapshot: b.is_snapshot,
      account: if(b.account, do: %{id: b.account.id, name: b.account.name, bank: b.account.bank})
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    String.to_integer(s)
  rescue
    _ -> default
  end
end
