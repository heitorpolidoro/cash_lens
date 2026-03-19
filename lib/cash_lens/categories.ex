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
    from(c in Category,
      left_join: p in assoc(c, :parent),
      order_by: [asc: coalesce(p.name, c.name), asc: c.name],
      preload: [:parent]
    )
    |> Repo.all()
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
  Gets a list of IDs including the category itself and all its immediate children.
  """
  def get_category_ids_with_children(nil), do: []
  def get_category_ids_with_children(category_id) do
    child_ids = 
      Repo.all(from c in Category, where: c.parent_id == ^category_id, select: c.id)
    
    [category_id | child_ids]
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
    Repo.delete(category)
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
