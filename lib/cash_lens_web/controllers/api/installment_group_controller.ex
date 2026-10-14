defmodule CashLensWeb.Api.InstallmentGroupController do
  use CashLensWeb, :controller

  alias CashLens.Installments

  def index(conn, _params) do
    groups = Installments.list_installment_groups(conn.assigns.current_user)
    json(conn, %{data: Enum.map(groups, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    group = Installments.get_installment_group!(conn.assigns.current_user, id)
    json(conn, %{data: serialize(group)})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    group = Installments.get_installment_group!(user, id)

    case Installments.update_installment_group(user, group, params) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, :not_found} -> not_found(conn)
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    group = Installments.get_installment_group!(user, id)

    case Installments.delete_installment_group(user, group) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :not_found} -> not_found(conn)
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp not_found(conn), do: send_resp(conn, 404, ~s({"error":"not found"}))

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
