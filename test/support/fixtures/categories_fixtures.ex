defmodule CashLens.CategoriesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Categories` context.
  """

  alias CashLens.Tenancy

  @doc """
  Generate a category. Accepts `:user` to create it for an explicit owner.
  """
  def category_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])
    {user, attrs} = Tenancy.pop_user(attrs)

    {:ok, category} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Enum.into(%{
          name: "category #{unique_id}"
        })
        |> CashLens.Categories.create_category()
      end)

    category
  end
end
