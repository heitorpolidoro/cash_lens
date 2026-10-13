defmodule CashLens.UsersFixtures do
  @moduledoc "Test helpers for creating users."

  alias CashLens.Repo
  alias CashLens.Users

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "a-long-valid-password"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{email: unique_user_email(), password: valid_user_password()})
  end

  @doc """
  Registers a user. Pass `enabled: true` to flip the operator switch. Users are
  email-confirmed unless `confirmed: false` is passed.
  """
  def user_fixture(attrs \\ %{}) do
    {enabled, attrs} = attrs |> Map.new() |> Map.pop(:enabled, false)
    {confirmed, attrs} = Map.pop(attrs, :confirmed, true)
    {:ok, user} = attrs |> valid_user_attributes() |> Users.register_user()

    changes =
      [enabled: enabled, confirmed_at: if(confirmed, do: DateTime.utc_now(:second))]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false end)

    if changes == [] do
      user
    else
      user |> Ecto.Changeset.change(changes) |> Repo.update!()
    end
  end

  @doc "Extracts the token (last path segment) of the first URL in the email's text body."
  def extract_token(%Swoosh.Email{text_body: body}) do
    [_, token] = Regex.run(~r{https?://[^\s]+/([^/\s]+)\s}, body)
    token
  end
end
