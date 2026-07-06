defmodule CashLensWeb.Api.InstallmentGroupController do
  use CashLensWeb, :controller

  alias CashLens.Installments

  def index(conn, _params) do
    groups = Installments.list_installment_groups()
    json(conn, %{data: Enum.map(groups, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    group = Installments.get_installment_group!(id)
    json(conn, %{data: serialize(group)})
  rescue
    Ecto.NoResultsError -> send_resp(conn, 404, ~s({"error":"not found"}))
  end

  def update(conn, %{"id" => id} = params) do
    group = Installments.get_installment_group!(id)

    case Installments.update_installment_group(group, params) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> send_resp(conn, 404, ~s({"error":"not found"}))
  end

  def delete(conn, %{"id" => id}) do
    group = Installments.get_installment_group!(id)

    case Installments.delete_installment_group(group) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> send_resp(conn, 404, ~s({"error":"not found"}))
  end

  defp serialize(g) do
    %{
      id: g.id,
      description_pattern: g.description_pattern,
      total_amount: g.total_amount,
      installments: g.installments,
      start_date: g.start_date,
      installment_amount: g.installment_amount
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
