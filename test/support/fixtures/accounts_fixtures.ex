defmodule CashLens.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Accounts` context.
  """

  @doc """
  Generate a account.
  """
  def account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{
        balance: "120.5",
        bank: "some bank",
        color: "some color",
        icon: "some icon",
        name: "some name"
      })
      |> CashLens.Accounts.create_account()

    account
  end
end
