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
  def list_categories(opts \\ []) do
    name_filter = Keyword.get(opts, :name)

    query = from(c in Category, order_by: [asc: c.slug])

    query =
      if name_filter && name_filter != "" do
        from(c in query, where: ilike(c.name, ^"%#{name_filter}%"))
      else
        query
      end

    categories = Repo.all(query)

    map = Map.new(categories, &{&1.id, &1})

    Enum.map(categories, fn category ->
      link_parents(category, map)
    end)
  end

  @doc """
  Groups a flat list of categories into the hierarchical structure the
  categories tree renders: `[{root_category, [descendant_category]}]`.

  Root categories keep the order of the given list, and every descendant is
  nested under its *top-level* ancestor in that same order — not only direct
  children. The UI only ever creates two levels, but a deeper category that
  already exists in the database is still listed under the root it belongs to,
  so it can always be reached, edited and deleted from `/categories`.

  A category whose ancestry is not fully present in the list is dropped, so the
  caller can filter the list before grouping without producing orphan rows.

  ## Examples

      iex> group_by_parent([root, child])
      [{root, [child]}]

  """
  def group_by_parent(categories) do
    by_id = Map.new(categories, &{&1.id, &1})
    {roots, descendants} = Enum.split_with(categories, &is_nil(&1.parent_id))
    by_root = Enum.group_by(descendants, &root_ancestor_id(&1, by_id, MapSet.new()))

    Enum.map(roots, fn root -> {root, Map.get(by_root, root.id, [])} end)
  end

  # Walks up to the top-level ancestor. `seen` guards against a cycle, which no
  # UI path can create but which nothing in the database prevents either;
  # `nil` (an unknown or cyclic ancestry) drops the category from the tree.
  defp root_ancestor_id(category, by_id, seen) do
    cond do
      MapSet.member?(seen, category.id) ->
        nil

      is_nil(category.parent_id) ->
        category.id

      true ->
        case Map.get(by_id, category.parent_id) do
          nil -> nil
          parent -> root_ancestor_id(parent, by_id, MapSet.put(seen, category.id))
        end
    end
  end

  defp link_parents(category, map), do: link_parents(category, map, MapSet.new())

  # Builds the nested `parent` chain. `seen` guards against a cycle in
  # `parent_id`: no UI path can create one, but nothing in the database
  # prevents it, and an unguarded walk here does not fail on a cycle — it never
  # returns, because each step allocates another level of a chain that has no
  # end. The chain is cut where it would repeat, which leaves the ancestry
  # truncated but keeps every category loadable, so a cycle can still be seen
  # and repaired from the UI. `group_by_parent/1` guards the same way.
  defp link_parents(category, map, seen) do
    cond do
      MapSet.member?(seen, category.id) ->
        %{category | parent: nil}

      is_nil(category.parent_id) ->
        %{category | parent: nil}

      true ->
        case Map.get(map, category.parent_id) do
          nil ->
            %{category | parent: nil}

          parent ->
            %{category | parent: link_parents(parent, map, MapSet.put(seen, category.id))}
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
  Appends `keyword` to a category's `keywords`, the list `AutoCategorizer`
  matches every imported description against.

  Idempotent and whitespace-forgiving: a blank keyword, or one the category
  already carries, leaves the record untouched and still returns `{:ok, ...}`.
  Comparison mirrors the matcher -- it upcases and collapses runs of
  whitespace -- so "COMGAS " never lands beside an existing "comgas".

  The separator is `", "`, the format the field already holds.
  """
  def add_keyword(%Category{} = category, keyword) when is_binary(keyword) do
    trimmed = normalize_keyword(keyword)

    cond do
      trimmed == "" -> {:ok, category}
      keyword?(category, trimmed) -> {:ok, category}
      true -> update_category(category, %{keywords: append_keyword(category.keywords, trimmed)})
    end
  end

  defp keyword?(%Category{keywords: keywords}, trimmed) do
    keywords
    |> split_keywords()
    |> Enum.any?(&(String.upcase(&1) == String.upcase(trimmed)))
  end

  defp append_keyword(keywords, trimmed) do
    case split_keywords(keywords) do
      [] -> trimmed
      existing -> Enum.join(existing ++ [trimmed], ", ")
    end
  end

  # `AutoCategorizer` splits on commas and newlines alike, so both have to be
  # read as separators here or a rule appended after a newline-separated list
  # would be invisible to the duplicate check.
  defp split_keywords(nil), do: []

  defp split_keywords(keywords) do
    keywords
    |> String.split([",", "\n", "\r\n"])
    |> Enum.map(&normalize_keyword/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_keyword(keyword) do
    keyword |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  @doc """
  Every pair of keywords, on different categories, that makes a description
  ambiguous -- as `[%{text:, category:, shadowed_by_text:, shadowed_by:}]`.

  `AutoCategorizer` matches by substring and takes the FIRST category the
  database hands back, with no `order_by`: the winner is the physical row
  order, which an ordinary `UPDATE` reshuffles. So whenever one keyword
  contains another, descriptions matching the longer one match both rules and
  the category that wins is not something anyone chose. "HAIR" on Cuidados
  Pessoais and "ALEX HAIR" on Cabeleireiro is exactly that: "PAG*ALEX HAIR
  STUDIO" currently lands on Cuidados Pessoais, and editing either category
  could silently flip it.

  Equal keywords are reported once, in the order the categories come back, so
  a plain duplicate produces one finding rather than two mirrored ones.

  Reported, never resolved: which category should own an ambiguous description
  is a judgement about meaning, and the app does not get to make it quietly.
  """
  def keyword_conflicts(categories \\ nil) do
    categories = categories || list_categories()

    indexed =
      for category <- categories,
          text <- split_keywords(category.keywords),
          do: %{text: text, upcased: String.upcase(text), category: category}

    for a <- indexed,
        b <- indexed,
        a.category.id != b.category.id,
        conflict?(a, b),
        do: %{
          text: a.text,
          category: a.category,
          shadowed_by_text: b.text,
          shadowed_by: b.category,
          # Two categories claiming the SAME text is a different sentence from
          # one keyword swallowing another, and reads as nonsense in the shared
          # phrasing ("HAIR e HAIR casam com a mesma descrição"). The screens
          # branch on this rather than comparing the two strings themselves.
          exact?: String.upcase(a.text) == String.upcase(b.text)
        }
  end

  @doc """
  The conflicts `keyword` would create, as if it belonged to `category_id`.

  Used by the forms to warn before the keyword is saved, so the same rule that
  describes an existing clash also describes one about to be made.
  """
  def keyword_conflicts_for(keyword, category_id) when is_binary(keyword) do
    case normalize_keyword(keyword) do
      "" ->
        []

      trimmed ->
        candidate = %Category{id: category_id, name: "", keywords: trimmed}

        list_categories()
        |> Enum.reject(&(&1.id == category_id))
        |> then(&keyword_conflicts([candidate | &1]))
        |> Enum.filter(&(&1.category.id == category_id or &1.shadowed_by.id == category_id))
    end
  end

  # `b` conflicts with `a` when a description matching `b` also matches `a`.
  #
  # Two identical keywords shadow each other, so the pair would be reported
  # twice; the id comparison picks one side and reports it once. It is an
  # arbitrary tie-break, but a stable one, which is what keeps the warning from
  # listing the same clash in both directions.
  defp conflict?(%{upcased: same} = a, %{upcased: same} = b), do: a.category.id < b.category.id
  defp conflict?(a, b), do: String.contains?(b.upcased, a.upcased)

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
