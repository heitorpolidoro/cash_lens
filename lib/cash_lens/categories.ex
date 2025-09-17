# TODO Review
defmodule CashLens.Categories do
  @moduledoc """
  The Categories context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Categories.Category
  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of categories.

  ## Examples

      iex> list_categories()
      [%Category{}, ...]

  """
  def list_categories do
    Repo.all(Category)
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
  def get_category!(id) do
    case :persistent_term.get(:categories, %{})[id] do
      nil ->
        load_categories()
        :persistent_term.get(:categories, %{})[id] || Repo.get!(Category, id)

      category ->
        category
    end
  end

  def load_categories do
    categories =
      Category
      |> Repo.all()
      |> Map.new(fn c -> {c.id, c} end)

    :persistent_term.put(:categories, categories)
  end

  @doc """
  Creates a category.

  ## Examples

      iex> create_category(%{field: value})
      {:ok, %Category{}}

      iex> create_category(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_category(attrs \\ %{}) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
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
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking category changes.

  ## Examples

      iex> change_category(category)
      %Ecto.Changeset{data: %Category{}}

  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  def monthly_summary do
    # TODO select which accounts
    from(t in Transaction,
      join: c in assoc(t, :category),
      where: c.name != "Transfer",
      select: %{
        month: fragment("date_trunc('month', ?)", t.datetime),
        category: c,
        total: -sum(t.amount)
      },
      group_by: [fragment("date_trunc('month', ?)", t.datetime), c.id],
      order_by: [fragment("date_trunc('month', ?)", t.datetime)]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn item, acc ->
      info = Map.get(acc, item.month, %{})
      category_name = item.category.name
      month_info = Map.put(info, category_name, item.total)

      acc
      |> Map.put(item.month, month_info)
      |> Map.update(:categories, [category_name], fn x -> x ++ [category_name] end)
    end)
  end
end
