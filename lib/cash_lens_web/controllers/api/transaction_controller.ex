defmodule CashLensWeb.Api.TransactionController do
  use CashLensWeb, :controller

  alias CashLens.Transactions

  @default_page_size 50
  @max_page_size 200

  # Supports filters:
  #   category_id=null | <uuid>   search=<text>
  #   account_id=<uuid>           type=income|expense
  #   date_from=YYYY-MM-DD        date_to=YYYY-MM-DD
  #   month=<1-12>                year=<YYYY>
  #   sort_order=asc|desc         page=<n>   page_size=<n>
  def index(conn, params) do
    page = parse_int(params["page"], 1)
    page_size = params["page_size"] |> parse_int(@default_page_size) |> min(@max_page_size)
    filters = build_filters(params)

    transactions = Transactions.list_transactions(filters, page, page_size)
    total = Transactions.count_transactions(filters)

    json(conn, %{
      data: Enum.map(transactions, &serialize/1),
      meta: %{
        page: page,
        page_size: page_size,
        total: total,
        total_pages: ceil(total / page_size)
      }
    })
  end

  def show(conn, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)
    json(conn, %{data: serialize(transaction)})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def update(conn, %{"id" => id} = params) do
    transaction = Transactions.get_transaction!(id)

    attrs =
      params
      |> Map.take(["description", "amount", "date", "notes", "reimbursement_status"])
      |> maybe_put_category(params["category_id"])

    case Transactions.update_transaction(transaction, attrs) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)

    case Transactions.delete_transaction(transaction) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp maybe_put_category(attrs, nil), do: attrs
  defp maybe_put_category(attrs, "null"), do: Map.put(attrs, "category_id", nil)
  defp maybe_put_category(attrs, id), do: Map.put(attrs, "category_id", id)

  defp build_filters(params) do
    %{}
    |> put_filter(params, "category_id", fn
      "null" -> "nil"
      v -> v
    end)
    |> put_filter(params, "account_id")
    |> put_filter(params, "search")
    |> put_filter(params, "date_from")
    |> put_filter(params, "date_to")
    |> put_filter(params, "date")
    |> put_filter(params, "month")
    |> put_filter(params, "year")
    |> put_filter(params, "type")
    |> put_filter(params, "sort_order")
  end

  defp put_filter(acc, params, key, transform \\ & &1) do
    case Map.get(params, key) do
      nil -> acc
      "" -> acc
      v -> Map.put(acc, key, transform.(v))
    end
  end

  defp serialize(t) do
    %{
      id: t.id,
      date: t.date,
      description: t.description,
      amount: t.amount,
      notes: t.notes,
      transfer_key: t.transfer_key,
      reimbursement_status: t.reimbursement_status,
      installment_number: t.installment_number,
      account: account_ref(t.account),
      category: category_ref(t.category)
    }
  end

  defp account_ref(%{id: id, name: name, bank: bank}), do: %{id: id, name: name, bank: bank}
  defp account_ref(nil), do: nil

  defp category_ref(%{id: id, name: name, slug: slug}), do: %{id: id, name: name, slug: slug}
  defp category_ref(nil), do: nil

  defp not_found(conn), do: send_resp(conn, 404, ~s({"error":"not found"}))

  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    String.to_integer(s)
  rescue
    _ -> default
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
