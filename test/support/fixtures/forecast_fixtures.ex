defmodule CashLens.ForecastFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Forecast` context.
  """

  alias CashLens.Tenancy

  def recurring_item_fixture(attrs \\ %{}) do
    {user, attrs} = Tenancy.pop_user(attrs)

    category_id =
      Map.get(attrs, :category_id) ||
        CashLens.CategoriesFixtures.category_fixture(%{type: "fixed", user: user}).id

    {:ok, item} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Enum.into(%{
          category_id: category_id,
          label: "some fixed bill",
          day_of_month: 10,
          amount: "-100.00"
        })
        |> CashLens.Forecast.create_recurring_item()
      end)

    item
  end
end
