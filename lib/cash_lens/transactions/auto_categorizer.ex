defmodule CashLens.Transactions.AutoCategorizer do
  @moduledoc """
  Handles automatic classification of transactions based on database rules.
  """
  import Ecto.Query
  alias CashLens.Repo
  alias CashLens.Categories.Category

  @doc """
  Analyzes a transaction map or struct and assigns a category_id based on DB rules.
  """
  def categorize(transaction_params) do
    description = String.upcase(transaction_params.description || "")
    
    # 1. Get all categories that have keywords defined
    rules = Repo.all(from c in Category, where: not is_nil(c.keywords) and c.keywords != "")

    # 2. Find first match
    matched_category = Enum.find(rules, fn category ->
      keywords = 
        category.keywords 
        |> String.split([",", "\n", "\r\n"])
        |> Enum.map(&String.trim/1) 
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(&String.upcase/1)
      
      match_word = Enum.find(keywords, fn k -> String.contains?(description, k) end)
      
      if match_word do
        IO.puts("MATCH FOUND: Keyword '#{match_word}' found in Description '#{description}' for category '#{category.name}'")
      end
      
      not is_nil(match_word)
    end)

    # 3. Apply category if matched
    if matched_category do
      IO.puts("Auto-categorized '#{description}' as '#{matched_category.name}'")
      Map.put(transaction_params, :category_id, matched_category.id)
    else
      # Fallback to hardcoded special rules if any (like transfer)
      check_special_rules(transaction_params, description)
    end
  end

  defp check_special_rules(params, description) do
    cond do
      String.contains?(description, ["BB MM OURO", "BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
        assign_category_by_slug(params, "transfer")
      true ->
        params
    end
  end

  defp assign_category_by_slug(params, slug) do
    case Repo.get_by(Category, slug: slug) do
      nil -> params
      category -> Map.put(params, :category_id, category.id)
    end
  end
end
