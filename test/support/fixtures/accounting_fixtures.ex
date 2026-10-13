defmodule CashLens.AccountingFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Accounting` context.
  """

  alias CashLens.Tenancy

  @doc """
  Generate a balance. Accepts `:user` to create it for an explicit owner.
  """
  def balance_fixture(attrs \\ %{}) do
    {user, attrs} = Tenancy.pop_user(attrs)

    account_id =
      attrs[:account_id] || CashLens.AccountsFixtures.account_fixture(%{user: user}).id

    {:ok, balance} =
      Tenancy.acting_as(user, fn ->
        attrs
        |> Enum.into(%{
          account_id: account_id,
          balance: "120.5",
          expenses: "120.5",
          final_balance: "120.5",
          income: "120.5",
          initial_balance: "120.5",
          month: 1,
          year: 2026
        })
        |> CashLens.Accounting.create_balance()
      end)

    balance
  end
end
