defmodule CashLens.PluggyFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Pluggy` context.
  """

  def pluggy_item_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    {:ok, item} =
      attrs
      |> Enum.into(%{
        item_id: "item-#{unique_id}",
        label: "Item #{unique_id}"
      })
      |> CashLens.Pluggy.create_item()

    item
  end
end
