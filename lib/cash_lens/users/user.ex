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
    |> validate_password()
    |> unsafe_validate_unique(:email, CashLens.Repo)
    |> unique_constraint(:email)
    |> hash_password()
    |> put_change(:session_nonce, new_nonce())
  end

  # Read at compile time; the file lives in the repo (priv/common_passwords.txt)
  # and is compared lowercased.
  @common_passwords_path Path.expand("../../../priv/common_passwords.txt", __DIR__)
  @external_resource @common_passwords_path
  @common_passwords @common_passwords_path
                    |> File.read!()
                    |> String.split("\n", trim: true)
                    |> MapSet.new(&String.downcase(String.trim(&1)))

  # Length is counted in bytes: bcrypt ignores everything past 72 bytes.
  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_change(:password, fn :password, password ->
      cond do
        byte_size(password) < 12 -> [password: "should be at least 12 character(s)"]
        byte_size(password) > 72 -> [password: "should be at most 72 byte(s)"]
        true -> []
      end
    end)
    |> validate_not_common()
    |> validate_not_email()
  end

  defp validate_not_common(changeset) do
    validate_change(changeset, :password, fn :password, password ->
      if MapSet.member?(@common_passwords, String.downcase(password)),
        do: [password: "is too common"],
        else: []
    end)
  end

  defp validate_not_email(changeset) do
    email = changeset |> get_field(:email) |> to_string() |> String.downcase()
    [local | _] = String.split(email, "@")

    validate_change(changeset, :password, fn :password, password ->
      lowered = String.downcase(password)

      if email != "" and lowered in [email, local],
        do: [password: "is too similar to your email"],
        else: []
    end)
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
