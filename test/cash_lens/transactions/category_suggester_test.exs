defmodule CashLens.Transactions.CategorySuggesterTest do
  use CashLens.DataCase, async: false

  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures
  import Ecto.Query

  alias CashLens.Repo
  alias CashLens.Transactions.CategorySuggester
  alias CashLens.Transactions.Transaction

  describe "suggest_for/1" do
    test "matches normalized descriptions (case, accents, spacing)" do
      category = category_fixture(name: "Padaria")
      transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)

      target = transaction_fixture(description: "  Padaria São José ", amount: "10.0")

      suggestions = CategorySuggester.suggest_for([target])

      assert suggestions[target.id] == %{
               category_id: category.id,
               category_name: "Padaria"
             }
    end

    test "picks the most frequent category for a description" do
      frequent = category_fixture(name: "Frequente")
      rare = category_fixture(name: "Rara")

      transaction_fixture(description: "MERCADO X", category_id: frequent.id, amount: "1.0")
      transaction_fixture(description: "MERCADO X", category_id: frequent.id, amount: "2.0")
      transaction_fixture(description: "MERCADO X", category_id: rare.id, amount: "3.0")

      target = transaction_fixture(description: "Mercado X", amount: "9.0")

      assert %{} = suggestions = CategorySuggester.suggest_for([target])
      assert suggestions[target.id].category_id == frequent.id
    end

    test "breaks frequency ties toward the most recent occurrence" do
      old_cat = category_fixture(name: "Antiga")
      new_cat = category_fixture(name: "Recente")

      old_tx =
        transaction_fixture(description: "FARMACIA Y", category_id: old_cat.id, amount: "1.0")

      new_tx =
        transaction_fixture(description: "FARMACIA Y", category_id: new_cat.id, amount: "2.0")

      # timestamps have second precision; set distinct inserted_at explicitly
      Repo.update_all(from(t in Transaction, where: t.id == ^old_tx.id),
        set: [inserted_at: ~U[2026-01-01 10:00:00Z]]
      )

      Repo.update_all(from(t in Transaction, where: t.id == ^new_tx.id),
        set: [inserted_at: ~U[2026-06-01 10:00:00Z]]
      )

      target = transaction_fixture(description: "Farmacia Y", amount: "9.0")

      assert CategorySuggester.suggest_for([target])[target.id].category_id == new_cat.id
    end

    test "returns no entry for descriptions without categorized history" do
      target = transaction_fixture(description: "NUNCA VISTA")
      assert CategorySuggester.suggest_for([target]) == %{}
    end

    test "ignores transactions that already have a category" do
      category = category_fixture(name: "Qualquer")
      categorized = transaction_fixture(description: "JA TEM", category_id: category.id)

      assert CategorySuggester.suggest_for([categorized]) == %{}
    end

    test "returns empty map for an empty list without querying" do
      assert CategorySuggester.suggest_for([]) == %{}
    end
  end

  describe "annotate/1" do
    test "fills the suggested_category virtual field on matches only" do
      category = category_fixture(name: "Padaria")
      transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)

      with_match = transaction_fixture(description: "Padaria São José", amount: "10.0")
      without_match = transaction_fixture(description: "OUTRA COISA", amount: "11.0")

      [a, b] = CategorySuggester.annotate([with_match, without_match])

      assert a.suggested_category == %{category_id: category.id, category_name: "Padaria"}
      assert is_nil(b.suggested_category)
    end
  end
end
