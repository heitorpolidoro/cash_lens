defmodule CashLens.Categories do
  @moduledoc """
  The Categories context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Categories.Category

  @doc """
  Returns the list of categories.

  ## Examples

      iex> list_categories()
      [%Category{}, ...]

  """
  def list_categories do
    categories =
      from(c in Category, order_by: [asc: c.slug])
      |> Repo.all()

    map = Map.new(categories, &{&1.id, &1})

    Enum.map(categories, fn category ->
      link_parents(category, map)
    end)
  end

  defp link_parents(category, map) do
    case category.parent_id do
      nil ->
        %{category | parent: nil}

      parent_id ->
        case Map.get(map, parent_id) do
          nil -> %{category | parent: nil}
          parent -> %{category | parent: link_parents(parent, map)}
        end
    end
  end

  @doc """
  Gets a single category.

  Raises `Ecto.NoResultsError` if the Category does not exist.

  ## Examples

      iex> get_category!(123)
      %Category{}

      iex> get_category!(456)
      ** (Ecto.NoResultsError)

  """
  def get_category!(id), do: Repo.get!(Category, id) |> Repo.preload(:parent)

  @doc """
  Gets a list of IDs including the category itself and all its descendants (children, grandchildren, etc.).
  """
  def get_category_ids_with_children(nil), do: []

  def get_category_ids_with_children(category_id) do
    initial_query =
      Category
      |> where([c], c.id == ^category_id)
      |> select([c], %{id: c.id})

    recursive_query =
      Category
      |> join(:inner, [c], ct in "category_tree", on: c.parent_id == ct.id)
      |> select([c], %{id: c.id})

    cte_query = initial_query |> union_all(^recursive_query)

    recursive_ctes(Category, true)
    |> with_cte("category_tree", as: ^cte_query)
    |> join(:inner, [c], ct in "category_tree", on: c.id == ct.id)
    |> select([c], c.id)
    |> Repo.all()
  end

  @doc """
  Gets a single category by its slug.
  """
  def get_category_by_slug(slug) do
    Repo.get_by(Category, slug: slug)
  end

  @doc """
  Creates a category.

  ## Examples

      iex> create_category(%{field: value})
      {:ok, %Category{}}

      iex> create_category(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:category_created)
  end

  @doc """
  Updates a category.

  ## Examples

      iex> update_category(category, %{field: new_value})
      {:ok, %Category{}}

      iex> update_category(category, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> Repo.update()
    |> broadcast(:category_updated)
  end

  @doc """
  Deletes a category.

  ## Examples

      iex> delete_category(category)
      {:ok, %Category{}}

      iex> delete_category(category)
      {:error, %Ecto.Changeset{}}

  """
  def delete_category(%Category{} = category) do
    category
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.no_assoc_constraint(:children)
    |> Repo.delete()
    |> broadcast(:category_deleted)
  end

  defp broadcast({:ok, category}, event) do
    Phoenix.PubSub.broadcast(CashLens.PubSub, "categories", {event, category})
    {:ok, category}
  end

  defp broadcast(error, _), do: error

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking category changes.

  ## Examples

      iex> change_category(category)
      %Ecto.Changeset{data: %Category{}}

  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end
end
