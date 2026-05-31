defmodule CashLens.Transactions.AutoCategorizer do
  @moduledoc """
  Handles automatic classification of transactions based on database rules.
  """
  import Ecto.Query

  alias CashLens.Categories.Category
  alias CashLens.Repo
  alias CashLens.Transactions.TransferRule

  @doc """
  Analyzes a transaction map or struct and assigns a category_id based on DB rules.
  """
  def categorize(transaction_params) do
    description =
      (transaction_params.description || "")
      |> String.upcase()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    # 1. Get all categories that have keywords defined
    rules = Repo.all(from c in Category, where: not is_nil(c.keywords) and c.keywords != "")

    require Logger

    # 2. Find first match
    matched_category =
      Enum.find(rules, fn category ->
        keywords =
          category.keywords
          |> String.split([",", "\n", "\r\n"])
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&String.upcase/1)

        match_word = Enum.find(keywords, fn k -> String.contains?(description, k) end)

        not is_nil(match_word)
      end)

    # 3. Apply category if matched
    if matched_category do
      Logger.info("Auto-categorized '#{description}' as '#{matched_category.name}'")

      params = Map.put(transaction_params, :category_id, matched_category.id)

      # Auto-mark as reimbursable if category defines it
      if matched_category.default_reimbursable do
        Map.put(params, :reimbursement_status, "pending")
      else
        params
      end
    else
      # Fallback: check transfer rules, then hardcoded special rules
      check_transfer_rules(transaction_params) ||
        check_special_rules(transaction_params, description)
    end
  end

  defp check_transfer_rules(params) do
    account_id = get_field_value(params, :account_id)
    description_lower = String.downcase(get_field_value(params, :description) || "")

    if account_id do
      matching_rule =
        Repo.one(
          from r in TransferRule,
            where: r.source_account_id == ^account_id,
            where:
              fragment(
                "? = ANY(SELECT lower(p) FROM unnest(?) AS p)",
                ^description_lower,
                r.description_patterns
              ),
            limit: 1
        )

      if matching_rule do
        assign_category_by_slug(params, "transfer")
      end
    end
  end

  defp check_special_rules(params, description) do
    if String.contains?(description, ["BB MM OURO", "BB RENDE FÁCIL", "BB RENDE FACIL"]) do
      assign_category_by_slug(params, "transfer")
    else
      params
    end
  end

  defp get_field_value(%_{} = struct, field), do: Map.get(struct, field)
  defp get_field_value(map, field) when is_map(map), do: map[field] || map[Atom.to_string(field)]

  defp assign_category_by_slug(params, slug) do
    case Repo.get_by(Category, slug: slug) do
      nil -> params
      category -> Map.put(params, :category_id, category.id)
    end
  end
end
