defmodule CashLens.Ownership do
  @moduledoc """
  Tenant-isolation helpers: which schemas belong to a user, the application-level
  query filter and the ownership check for references.

  Every domain table carries a NOT NULL `user_id`. Nothing fills it in: contexts
  take the `%CashLens.Users.User{}` first and set `user_id` on what they create,
  and read through `scope/2`. Tooling picks its user with
  `operator_user!/1`.

  The pin kept by `put_user_id/1` / `pinned_user_id/0` is only what
  `CashLens.Repo` binds for row-level security.
  """

  import Ecto.Query

  alias CashLens.Repo
  alias CashLens.Users.User

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
  @operator_usage "pass --user <email> to pick the user the data belongs to"

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

  @doc """
  Resolves the user that mix tasks and seeds act for and pins it for the calling
  process (row-level security needs a pinned user for every read and write that
  follows). Tooling has no session, so it names its user explicitly: the
  `--user <email>` option, or `CASH_LENS_OPERATOR_EMAIL` for seeds.

    * with an email, returns the user having it, or raises `Mix.Error`;
    * with `nil`, returns the only user, or raises `Mix.Error` when there are
      none or several.

  Never creates a user. Call it before any write.
  """
  def operator_user!(email) when is_binary(email) and email != "" do
    case Repo.get_by(User, email: email) do
      nil -> Mix.raise("no user has the email #{email}")
      user -> pin_operator(user)
    end
  end

  def operator_user!(nil) do
    case Repo.all(from(u in User, limit: 2)) do
      [user] -> pin_operator(user)
      [] -> Mix.raise("no user exists: register one first")
      _several -> Mix.raise("several users exist: #{@operator_usage}")
    end
  end

  def operator_user!(_email), do: operator_user!(nil)

  @doc "Reads the `--user` option out of `args`; returns `{email_or_nil, remaining_args}`."
  def operator_parse_args(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [user: :string])
    {Keyword.get(opts, :user), rest}
  end

  defp pin_operator(user) do
    Repo.put_current_user_id(user.id)
    user
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
