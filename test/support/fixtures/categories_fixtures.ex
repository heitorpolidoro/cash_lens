defmodule CashLens.CategoriesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Categories` context.
  """

  @doc """
  Generate a category.
  """
  def category_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    {:ok, category} =
      attrs
      |> Enum.into(%{
        name: "category #{unique_id}",
        slug: "category-#{unique_id}"
      })
      |> CashLens.Categories.create_category()

    category
  end
end
