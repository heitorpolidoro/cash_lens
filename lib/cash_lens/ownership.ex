defmodule CashLens.Ownership do
  @moduledoc """
  Resolves which user owns the rows the app inserts.

  Every domain table carries a `user_id`. Until the web layer scopes requests
  by the logged-in user (later CL-20 parts), inserts that do not name an owner
  fall back to the *operator*:

    1. the owner pinned for the current process with `put_user_id/1`;
    2. the user whose email is in `CASH_LENS_OPERATOR_EMAIL`;
    3. the only user in the table.

  Anything else raises, because guessing an owner for financial data is worse
  than failing. `Repo.insert/2` and `Repo.insert!/2` apply this automatically
  (see `CashLens.Repo`); bulk inserts call `current_user_id!/0` themselves.
  """

  import Ecto.Query

  alias CashLens.Repo

  # Ordered so that rows referencing others (transactions, ...) come first:
  # `CashLens.Privacy` deletes in this order.
  @domain_schemas [
    CashLens.Transactions.RejectedReimbursementPair,
    CashLens.Transactions.Transaction,
    CashLens.Accounting.Balance,
    CashLens.Transactions.BulkIgnorePattern,
    CashLens.Transactions.TransferRule,
    CashLens.Forecast.RecurringItem,
    CashLens.CreditCards.Statement,
    CashLens.Imports.ImportedFile,
    CashLens.Imports.ImportRun,
    CashLens.Installments.InstallmentGroup,
    CashLens.Accounts.Account,
    CashLens.Categories.Category
  ]

  @pdict_key :cash_lens_owner_user_id
  @env_var "CASH_LENS_OPERATOR_EMAIL"

  @doc "The schemas whose rows belong to a user, dependents first."
  def domain_schemas, do: @domain_schemas

  @doc "Pins the owner of rows inserted by the calling process."
  def put_user_id(user_id) do
    Process.put(@pdict_key, user_id)
    :ok
  end

  @doc "The owner pinned for the calling process, or `nil`."
  def pinned_user_id, do: Process.get(@pdict_key)

  @doc """
  Restricts `queryable` to the rows owned by `user` (`user_id == user.id`).

  The filter is explicit and does not rely on the pinned user or on row-level
  security, so it is the application-level half of tenant isolation.
  """
  def scope(queryable, %CashLens.Users.User{id: user_id}) do
    from(x in queryable, where: x.user_id == ^user_id)
  end

  @doc """
  Adds an error on `field` when the id it references (a row of `schema`) does
  not exist or belongs to a user other than the changeset's owner.

  Does nothing when `field` has no change. Fails closed: with no `user_id` on
  the changeset any non-nil reference is an error. The lookup runs as the
  changeset owner, so it works when nothing is pinned.
  """
  def validate_owned(%Ecto.Changeset{} = changeset, field, schema) do
    case Ecto.Changeset.get_change(changeset, field) do
      nil ->
        changeset

      id ->
        if owned?(Ecto.Changeset.get_field(changeset, :user_id), id, schema) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, field, "does not exist")
        end
    end
  end

  defp owned?(nil, _id, _schema), do: false

  defp owned?(owner_id, id, schema) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.with_user(owner_id, fn ->
          Repo.exists?(from s in schema, where: s.id == ^id and s.user_id == ^owner_id)
        end)

      :error ->
        false
    end
  end

  @doc """
  The operator user: the one named by `CASH_LENS_OPERATOR_EMAIL`, or the only
  user when the variable is unset or empty. Raises when no unambiguous user
  exists and never creates one. For mix tasks and seeds only.
  """
  def operator_user! do
    case System.get_env(@env_var) do
      email when is_binary(email) and email != "" ->
        Repo.get_by(CashLens.Users.User, email: email) ||
          raise "#{@env_var}=#{email} does not match any user"

      _ ->
        case Repo.all(from(u in CashLens.Users.User, limit: 2)) do
          [user] -> user
          [] -> raise "no user exists: register one first"
          _ -> raise "several users exist: set #{@env_var} to pick the operator"
        end
    end
  end

  @doc "Pins the operator (see the moduledoc) for the calling process; for maintenance code."
  def pin_operator! do
    put_user_id(current_user_id!())
  end

  # TRANSITIONAL: removed when CL-51 converts the caller
  @doc "The `%User{}` for `current_user_id!/0`, for callers not yet converted to take a user."
  def current_user! do
    Repo.get!(CashLens.Users.User, current_user_id!())
  end

  @doc "Returns the id that should own a new row, raising when it is ambiguous."
  def current_user_id! do
    Process.get(@pdict_key) || operator_user_id!()
  end

  @doc "Fills `user_id` on a struct or changeset when it is still blank."
  def assign(%Ecto.Changeset{data: %{__struct__: mod}} = changeset) do
    if user_owned?(mod) and is_nil(Ecto.Changeset.get_field(changeset, :user_id)) do
      Ecto.Changeset.put_change(changeset, :user_id, current_user_id!())
    else
      changeset
    end
  end

  def assign(%{__struct__: mod, user_id: nil} = struct) do
    if user_owned?(mod), do: Map.put(struct, :user_id, current_user_id!()), else: struct
  end

  def assign(other), do: other

  defp user_owned?(mod) do
    mod in @domain_schemas
  end

  defp operator_user_id! do
    case System.get_env(@env_var) do
      email when is_binary(email) and email != "" ->
        Repo.one(from u in "users", where: u.email == ^email, select: type(u.id, :binary_id)) ||
          raise "#{@env_var}=#{email} does not match any user"

      _ ->
        case Repo.all(from u in "users", select: type(u.id, :binary_id), limit: 2) do
          [id] -> id
          [] -> maybe_create_owner!()
          _ -> raise "several users exist: set #{@env_var} to pick the owner of new data"
        end
    end
  end

  # Tests insert domain rows without registering anyone first.
  defp maybe_create_owner! do
    if Application.get_env(:cash_lens, :auto_create_owner, false) do
      {:ok, user} =
        CashLens.Users.register_user(%{
          email: "owner#{System.unique_integer([:positive])}@example.com",
          password: "a-long-valid-password"
        })

      user.id
    else
      raise "no user exists: register one before importing data"
    end
  end
end
