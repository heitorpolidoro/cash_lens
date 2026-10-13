defmodule CashLens.Users.User do
  @moduledoc """
  A person who can sign in. A new user is created disabled (`enabled: false`);
  the operator enables it by hand in the database before it can see any data.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :enabled, :boolean, default: false
    field :session_nonce, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc "Sign-up changeset. `enabled` is never cast: it is operator-controlled."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^ @]+@[^ @]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 12, max: 72)
    |> unsafe_validate_unique(:email, CashLens.Repo)
    |> unique_constraint(:email)
    |> hash_password()
    |> put_change(:session_nonce, new_nonce())
  end

  def new_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc "True when `password` matches the stored hash."
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
