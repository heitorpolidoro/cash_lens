defmodule CashLens.Users do
  @moduledoc """
  Users and their credentials. Named `Users` because `CashLens.Accounts` is the
  bank-account context.
  """
  alias CashLens.Repo
  alias CashLens.Users.User

  def get_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  def get_user(_), do: nil

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc "Returns the user when email and password match, otherwise nil."
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_, _), do: nil

  @doc "Invalidates every session issued so far for `user`."
  def rotate_session_nonce(%User{} = user) do
    user |> Ecto.Changeset.change(session_nonce: User.new_nonce()) |> Repo.update()
  end

  def register_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end
end
