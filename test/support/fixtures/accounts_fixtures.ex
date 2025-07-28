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
        bank_name: "some bank_name",
        name: "some name",
        parser: "some parser",
        type: "checking"
      })
      |> CashLens.Accounts.create_account()

    account
  end
end
