defmodule CashLens.Privacy do
  @moduledoc """
  Self-service data export and account deletion (LGPD).

  Both operate on one registry of user-owned schemas, `@owned`. Shared financial
  data (accounts, transactions, ...) is global today, owned by no user, and is
  never exported or deleted here. A table that gains a `user_id` in the
  tenant-ownership work must be added to the registry.

  Each entry is `{schema, owner_field, omitted_fields}`. The `User` row itself is
  last, so dependents are deleted first.
  """
  import Ecto.Query

  alias CashLens.Audit.LoginAttempt
  alias CashLens.Repo
  alias CashLens.Users.User
  alias CashLens.Users.UserToken

  @owned [
    {UserToken, :user_id, [:token]},
    {LoginAttempt, :user_id, []},
    {User, :id, [:hashed_password, :session_nonce]}
  ]

  def owned_schemas, do: Enum.map(@owned, &elem(&1, 0))

  @doc "Every owned row of `user`, as JSON-encodable maps keyed by table name."
  def export(%User{id: user_id}) do
    Map.new(@owned, fn {schema, owner_field, omitted} ->
      rows =
        schema
        |> owned_query(owner_field, user_id)
        |> Repo.all()
        |> Enum.map(&row_to_map(&1, schema, omitted))

      {schema.__schema__(:source), rows}
    end)
  end

  @doc """
  Deletes every owned row of `user` in one transaction, provided `password` is
  the user's current password.
  """
  def delete_account(%User{id: user_id} = user, password) do
    if User.valid_password?(user, password) do
      Repo.transaction(fn ->
        Enum.each(@owned, &delete_owned(&1, user_id))
      end)
    else
      {:error, :invalid_password}
    end
  end

  defp delete_owned({schema, owner_field, _omitted}, user_id) do
    schema |> owned_query(owner_field, user_id) |> Repo.delete_all()
  end

  defp owned_query(schema, owner_field, user_id),
    do: from(r in schema, where: field(r, ^owner_field) == ^user_id)

  defp row_to_map(row, schema, omitted) do
    schema.__schema__(:fields)
    |> Enum.reject(&(&1 in omitted))
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(row, &1)})
  end
end
