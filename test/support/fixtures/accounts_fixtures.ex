defmodule CashLens.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Accounts` context.
  """

  @doc """
  Generate a account.
  """
  def account_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    {:ok, account} =
      attrs
      |> Enum.into(%{
        bank_name: "bank_name_#{unique_id}",
        name: "account_name_#{unique_id}",
        type: "checking"
      })
      |> CashLens.Accounts.create_account()

    account
  end
end
