defmodule CashLensWeb.Api.CategoryController do
  use CashLensWeb, :controller

  alias CashLens.Categories

  # Supports: search=<text>
  def index(conn, params) do
    categories = Categories.list_categories(name: params["search"])
    json(conn, %{data: Enum.map(categories, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    category = Categories.get_category!(id)
    json(conn, %{data: serialize(category)})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, params) do
    case Categories.create_category(params) do
      {:ok, category} ->
        conn |> put_status(201) |> json(%{data: serialize(category)})

      {:error, cs} ->
        conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    category = Categories.get_category!(id)

    case Categories.update_category(category, params) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{"id" => id}) do
    category = Categories.get_category!(id)

    case Categories.delete_category(category) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  defp serialize(c) do
    %{
      id: c.id,
      name: c.name,
      slug: c.slug,
      keywords: c.keywords,
      type: c.type,
      default_reimbursable: c.default_reimbursable,
      parent: if(c.parent, do: %{id: c.parent.id, name: c.parent.name, slug: c.parent.slug})
    }
  end

  defp not_found(conn), do: send_resp(conn, 404, ~s({"error":"not found"}))

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
