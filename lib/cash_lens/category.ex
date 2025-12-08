defmodule CashLens.Category do
  @moduledoc """
  Category utilities.

  Provides helpers to list categories from transactions.
  """

  @collection "transactions"

  @doc """
  Returns the unique, non-empty categories present in transactions.
  """
  def list_categories do
    case Mongo.distinct(:mongo, @collection, "category", %{}) do
      {:ok, values} when is_list(values) ->
        (values ++ ["Transfer"])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Case-insensitive search of categories by substring, returning up to `limit` results.

  Falls back to filtering `list_categories/0` in memory which is fine for small sets.
  """
  def search_categories(term, limit \\ 10) when is_binary(term) do
    q = term |> String.trim()

    if q == "" do
      []
    else
      list_categories()
      |> Enum.filter(fn cat -> String.contains?(String.downcase(cat), String.downcase(q)) end)
      |> Enum.take(limit)
    end
  end
end
