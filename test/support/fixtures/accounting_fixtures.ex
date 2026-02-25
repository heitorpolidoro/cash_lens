defmodule CashLens.AccountingFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Accounting` context.
  """

  @doc """
  Generate a balance.
  """
  def balance_fixture(attrs \\ %{}) do
    {:ok, balance} =
      attrs
      |> Enum.into(%{
        balance: "120.5",
        expenses: "120.5",
        final_balance: "120.5",
        income: "120.5",
        initial_balance: "120.5",
        month: 42,
        year: 42
      })
      |> CashLens.Accounting.create_balance()

    balance
  end
end
