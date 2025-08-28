defmodule CashLens.CategoriesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Categories` context.
  """

  alias CashLens.Categories

  @doc """
  Generate a category.
  """
  def category_fixture(attrs \\ %{}) do
    {:ok, category} =
      attrs
      |> Enum.into(%{
        name: "Test Category #{System.unique_integer([:positive])}"
      })
      |> Categories.create_category()

    category
  end
end
