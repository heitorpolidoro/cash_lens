defmodule CashLens.Transactions.CategorySuggester do
  @moduledoc """
  Suggests categories for uncategorized transactions based on how identical
  descriptions (normalized via `Transaction.normalize_description/1`) were
  categorized in the past. Suggestions are computed on the fly and are never
  applied without explicit user confirmation in the UI.
  """
  import Ecto.Query

  alias CashLens.Categories.Category
  alias CashLens.Ownership
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction
  alias CashLens.Users.User

  @doc """
  Returns `%{transaction_id => %{category_id: ..., category_name: ...}}` for
  the uncategorized transactions whose normalized description matches
  previously categorized transactions. The most frequent category wins; ties
  break toward the most recently inserted occurrence.
  """
  def suggest_for(%User{} = user, transactions) do
    targets =
      transactions
      |> Enum.filter(&(is_nil(&1.category_id) and not is_nil(&1.description)))
      |> Enum.map(&{&1.id, Transaction.normalize_description(&1.description)})

    if targets == [] do
      %{}
    else
      history = history_by_normalized_description(user)

      for {id, normalized} <- targets,
          suggestion = history[normalized],
          into: %{} do
        {id, suggestion}
      end
    end
  end

  @doc """
  Fills the `:suggested_category` virtual field of uncategorized transactions
  that have a suggestion. Other transactions pass through unchanged.
  """
  def annotate(%User{} = user, transactions) do
    suggestions = suggest_for(user, transactions)

    Enum.map(transactions, fn tx ->
      case suggestions[tx.id] do
        nil -> tx
        suggestion -> %{tx | suggested_category: suggestion}
      end
    end)
  end

  defp history_by_normalized_description(user) do
    # `description` can be nil on rows inserted outside the changeset (and such a
    # row can later gain a category via update_transaction_category, which only
    # casts category_id) — normalize_description/1 would crash on it.
    categories = Ownership.scope(Category, user)

    from(t in Ownership.scope(Transaction, user),
      where: not is_nil(t.category_id) and not is_nil(t.description),
      join: c in ^categories,
      on: c.id == t.category_id,
      select: {t.description, t.inserted_at, c.id, c.name}
    )
    |> Repo.all()
    |> Enum.group_by(fn {description, _at, _cat_id, _name} ->
      Transaction.normalize_description(description)
    end)
    |> Map.new(fn {normalized, rows} -> {normalized, pick_category(rows)} end)
  end

  # Most frequent category among the rows; frequency ties break toward the
  # category whose latest occurrence is most recent.
  defp pick_category(rows) do
    rows
    |> Enum.group_by(fn {_d, _at, cat_id, name} -> {cat_id, name} end)
    |> Enum.map(fn {{cat_id, name}, occurrences} ->
      latest =
        occurrences
        |> Enum.map(fn {_d, at, _i, _n} -> DateTime.to_unix(at) end)
        |> Enum.max()

      {length(occurrences), latest, %{category_id: cat_id, category_name: name}}
    end)
    |> Enum.max_by(fn {count, latest, _suggestion} -> {count, latest} end)
    |> elem(2)
  end
end
