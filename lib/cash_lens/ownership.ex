defmodule CashLens.Ownership do
  @moduledoc """
  Tenant-isolation helpers: which schemas belong to a user, the application-level
  query filter and the ownership check for references.

  Every domain table carries a NOT NULL `user_id`. Nothing fills it in: contexts
  take the `%CashLens.Users.User{}` first and set `user_id` on what they create,
  and read through `scope/2`. Tooling picks its user with
  `CashLens.Operator.user!/1`.

  The pin kept by `put_user_id/1` / `pinned_user_id/0` is only what
  `CashLens.Repo` binds for row-level security.
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
end
