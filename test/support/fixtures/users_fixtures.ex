defmodule CashLens.UsersFixtures do
  @moduledoc "Test helpers for creating users."

  alias CashLens.Repo
  alias CashLens.Users

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "a-long-valid-password"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{email: unique_user_email(), password: valid_user_password()})
  end

  @doc "Registers a user. Pass `enabled: true` to flip the operator switch."
  def user_fixture(attrs \\ %{}) do
    {enabled, attrs} = attrs |> Map.new() |> Map.pop(:enabled, false)
    {:ok, user} = attrs |> valid_user_attributes() |> Users.register_user()

    if enabled do
      user |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    else
      user
    end
  end
end
