defmodule CashLens.Transactions.AutoCategorizer do
  @moduledoc """
  Handles automatic classification of transactions based on rules.
  """
  alias CashLens.Categories

  @doc """
  Analyzes a transaction map and assigns a category_id if a rule matches.
  """
  def categorize(transaction_params) do
    description = String.upcase(transaction_params.description || "")
    
    cond do
      # Rules for Transfer (Transferência)
      String.contains?(description, ["BB MM OURO", "BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
        assign_category(transaction_params, "transfer")

      # Future rules can be added here (e.g., UBER -> transport)
      true ->
        transaction_params
    end
  end

  defp assign_category(params, slug) do
    case Categories.get_category_by_slug(slug) do
      nil -> params
      category -> Map.put(params, :category_id, category.id)
    end
  end
end
