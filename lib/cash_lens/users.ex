defmodule CashLens.Users do
  @moduledoc """
  Users and their credentials. Named `Users` because `CashLens.Accounts` is the
  bank-account context.
  """
  alias CashLens.Repo
  alias CashLens.Users.User
  alias CashLens.Users.UserNotifier
  alias CashLens.Users.UserToken

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

  ## Email confirmation

  @doc "Emails a confirmation link built by `url_fun` (token -> url). Refuses confirmed users."
  def deliver_confirmation_instructions(%User{} = user, url_fun) when is_function(url_fun, 1) do
    if User.confirmed?(user) do
      {:error, :already_confirmed}
    else
      {raw, token} = UserToken.build(user, "confirm")
      Repo.insert!(token)
      UserNotifier.deliver_confirmation_instructions(user, url_fun.(raw))
    end
  end

  @doc "Confirms the user the token belongs to. The token is deleted, so reuse fails."
  def confirm_user(raw_token) do
    with {:ok, query} <- UserToken.verify_query(raw_token, "confirm"),
         {%User{} = user, _token} <- Repo.one(query),
         {:ok, %{user: user}} <-
           Ecto.Multi.new()
           |> Ecto.Multi.update(
             :user,
             Ecto.Changeset.change(user, confirmed_at: DateTime.utc_now(:second))
           )
           |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts(user.id, ["confirm"]))
           |> Repo.transaction() do
      {:ok, user}
    else
      _ -> :error
    end
  end

  ## Password reset

  @doc "Emails a reset link. The caller shows the same answer for unknown emails."
  def deliver_reset_password_instructions(%User{} = user, url_fun) when is_function(url_fun, 1) do
    {raw, token} = UserToken.build(user, "reset_password")
    Repo.insert!(token)
    UserNotifier.deliver_reset_password_instructions(user, url_fun.(raw))
  end

  @doc "The user a valid, unexpired reset token belongs to, or nil."
  def get_user_by_reset_password_token(raw_token) do
    with {:ok, query} <- UserToken.verify_query(raw_token, "reset_password"),
         {%User{} = user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def change_user_password(%User{} = user, attrs \\ %{}),
    do: User.password_changeset(user, attrs)

  @doc """
  Sets a new password, deletes every reset token of the user and rotates the
  session nonce so existing sessions stop authenticating.
  """
  def reset_user_password(%User{} = user, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> Ecto.Changeset.put_change(:session_nonce, User.new_nonce())

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts(user.id, ["reset_password"])
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end
end
