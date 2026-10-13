defmodule CashLensWeb.Api.CategoryController do
  use CashLensWeb, :controller

  alias CashLens.Categories

  # Supports: search=<text>
  def index(conn, params) do
    categories = Categories.list_categories(conn.assigns.current_user, name: params["search"])
    json(conn, %{data: Enum.map(categories, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    category = Categories.get_category!(conn.assigns.current_user, id)
    json(conn, %{data: serialize(category)})
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def create(conn, params) do
    case Categories.create_category(conn.assigns.current_user, params) do
      {:ok, category} ->
        conn |> put_status(201) |> json(%{data: serialize(category)})

      {:error, cs} ->
        conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    category = Categories.get_category!(user, id)

    case Categories.update_category(user, category, params) do
      {:ok, updated} -> json(conn, %{data: serialize(updated)})
      {:error, :not_found} -> not_found(conn)
      {:error, cs} -> conn |> put_status(422) |> json(%{error: format_errors(cs)})
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    category = Categories.get_category!(user, id)

    case Categories.delete_category(user, category) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :not_found} -> not_found(conn)
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
      parent: serialize_parent(c.parent)
    }
  end

  # `parent` is only loaded by reads; a freshly created category has it unloaded.
  defp serialize_parent(%{id: id, name: name, slug: slug}), do: %{id: id, name: name, slug: slug}
  defp serialize_parent(_parent), do: nil

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "not found"})

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
