defmodule CashLens.Repo do
  @moduledoc """
  The runtime repo. It connects as the unprivileged `cash_lens_app` role, which
  owns nothing, so PostgreSQL row-level security (RLS) applies to every query.
  Schema changes go through `CashLens.MigrationRepo` (the owner role).

  ## Current user

  Every user-owned table has a policy `user_id = app.current_user_id`. This
  module is the single place that sets that setting. The user a process acts for
  is pinned with `put_current_user_id/1` (the web layer does it where the
  authenticated user is established) or scoped with `with_user/2`.

  While a user is pinned, every operation (queries, writes, `preload`,
  `transaction`) runs inside a transaction that first executes
  `set_config('app.current_user_id', id, true)`. The setting is transaction-local,
  so it disappears at COMMIT/ROLLBACK and can never leak to the next checkout of
  a pooled connection. With no user pinned nothing is set and the policies fail
  closed: no row is visible and no insert is accepted.

  `query/3` (raw SQL) and `stream/2` are not wrapped; run them inside
  `with_user/2` plus `transaction/2`, or accept that they see no user rows.
  """
  use Ecto.Repo,
    otp_app: :cash_lens,
    adapter: Ecto.Adapters.Postgres

  alias CashLens.Ownership
  alias Ecto.Adapters.SQL

  @setting "app.current_user_id"
  @bound_key :cash_lens_rls_bound

  # Domain rows are user-owned. Callers that do not name an owner get the
  # operator (see `CashLens.Ownership`).
  defoverridable insert: 2,
                 insert!: 2,
                 update: 2,
                 update!: 2,
                 delete: 2,
                 delete!: 2,
                 insert_or_update: 2,
                 insert_or_update!: 2,
                 insert_all: 3,
                 update_all: 3,
                 delete_all: 2,
                 all: 2,
                 all_by: 3,
                 one: 2,
                 one!: 2,
                 get: 3,
                 get!: 3,
                 get_by: 3,
                 get_by!: 3,
                 reload: 2,
                 reload!: 2,
                 exists?: 2,
                 aggregate: 3,
                 aggregate: 4,
                 preload: 3,
                 transact: 2

  @doc "Pins the user the calling process acts for."
  def put_current_user_id(user_id), do: Ownership.put_user_id(user_id)

  @doc "The user pinned for the calling process, or `nil`."
  def current_user_id, do: Ownership.pinned_user_id()

  @doc """
  Runs `fun` acting as `user_id`, then restores the previous user. Safe to nest:
  inside a transaction bound to another user the database setting is switched
  for the duration of `fun` and put back afterwards.
  """
  def with_user(user_id, fun) when is_function(fun, 0) do
    previous_pin = current_user_id()
    previous_bound = Process.get(@bound_key)
    put_current_user_id(user_id)

    try do
      if previous_bound && previous_bound != user_id do
        Process.put(@bound_key, user_id)
        set_setting(user_id)

        try do
          fun.()
        after
          set_setting(previous_bound)
        end
      else
        fun.()
      end
    after
      put_current_user_id(previous_pin)
      restore_bound(previous_bound)
    end
  end

  @doc """
  Raw SQL as the pinned user: `query/3` itself is not wrapped, this runs it in a
  transaction that binds the current user. Returns what `query/3` returns.
  """
  def scoped_query(sql, params \\ []) do
    {:ok, result} = transaction(fn -> query(sql, params, mode: :savepoint) end)
    result
  end

  def insert(struct_or_changeset, opts) do
    struct_or_changeset
    |> Ownership.assign()
    |> then(fn assigned -> bound(opts, &super(assigned, &1)) end)
  end

  def insert!(struct_or_changeset, opts) do
    struct_or_changeset
    |> Ownership.assign()
    |> then(fn assigned -> bound(opts, &super(assigned, &1)) end)
  end

  def update(changeset, opts), do: bound(opts, &super(changeset, &1))
  def update!(changeset, opts), do: bound(opts, &super(changeset, &1))
  def delete(struct, opts), do: bound(opts, &super(struct, &1))
  def delete!(struct, opts), do: bound(opts, &super(struct, &1))
  def insert_or_update(changeset, opts), do: bound(opts, &super(changeset, &1))
  def insert_or_update!(changeset, opts), do: bound(opts, &super(changeset, &1))
  def insert_all(source, entries, opts), do: bound(opts, &super(source, entries, &1))
  def update_all(queryable, updates, opts), do: bound(opts, &super(queryable, updates, &1))
  def delete_all(queryable, opts), do: bound(opts, &super(queryable, &1))
  def all(queryable, opts), do: bound(opts, &super(queryable, &1))
  def all_by(queryable, clauses, opts), do: bound(opts, &super(queryable, clauses, &1))
  def one(queryable, opts), do: bound(opts, &super(queryable, &1))
  def one!(queryable, opts), do: bound(opts, &super(queryable, &1))
  def get(queryable, id, opts), do: bound(opts, &super(queryable, id, &1))
  def get!(queryable, id, opts), do: bound(opts, &super(queryable, id, &1))
  def get_by(queryable, clauses, opts), do: bound(opts, &super(queryable, clauses, &1))
  def get_by!(queryable, clauses, opts), do: bound(opts, &super(queryable, clauses, &1))
  def reload(struct, opts), do: bound(opts, &super(struct, &1))
  def reload!(struct, opts), do: bound(opts, &super(struct, &1))
  def exists?(queryable, opts), do: bound(opts, &super(queryable, &1))
  # `aggregate/3` is either `(queryable, :count, opts)` or `(queryable, :sum, field)`.
  def aggregate(queryable, aggregate, opts) when is_list(opts),
    do: bound(opts, &super(queryable, aggregate, &1))

  def aggregate(queryable, aggregate, field), do: aggregate(queryable, aggregate, field, [])

  def aggregate(queryable, aggregate, field, opts),
    do: bound(opts, &super(queryable, aggregate, field, &1))

  def preload(structs, preloads, opts), do: bound(opts, &super(structs, preloads, &1))

  def transact(fun_or_multi, opts) do
    case binding_user() do
      nil ->
        super(fun_or_multi, opts)

      user_id ->
        previous = Process.put(@bound_key, user_id)

        try do
          user_id |> bind(fun_or_multi) |> super(opts) |> unbind(fun_or_multi)
        after
          restore_bound(previous)
        end
    end
  end

  # Runs `fun.(opts)` in a transaction that sets the current user first; plain
  # when no user is pinned or this process is already inside such a transaction.
  defp bound(opts, fun) do
    case binding_user() do
      nil ->
        fun.(opts)

      _user_id ->
        # Savepoint mode keeps a failed statement (e.g. a unique violation that
        # Ecto turns into a changeset error) from aborting the transaction.
        opts = Keyword.put_new(opts, :mode, :savepoint)
        {:ok, result} = transact(fn -> {:ok, fun.(opts)} end, [])
        result
    end
  end

  defp binding_user do
    case current_user_id() do
      nil -> nil
      user_id -> if Process.get(@bound_key) == user_id, do: nil, else: user_id
    end
  end

  defp restore_bound(nil), do: Process.delete(@bound_key)
  defp restore_bound(previous), do: Process.put(@bound_key, previous)

  defp bind(user_id, fun) when is_function(fun, 0) do
    fn -> with_setting(user_id, fun) end
  end

  defp bind(user_id, fun) when is_function(fun, 1) do
    fn repo -> with_setting(user_id, fn -> fun.(repo) end) end
  end

  defp bind(user_id, %Ecto.Multi{} = multi) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(@bound_key, fn _repo, _changes ->
      set_setting(user_id)
      {:ok, nil}
    end)
    |> Ecto.Multi.append(multi)
  end

  defp unbind({:ok, changes}, %Ecto.Multi{}) when is_map(changes),
    do: {:ok, Map.delete(changes, @bound_key)}

  defp unbind({:error, name, value, changes}, %Ecto.Multi{}),
    do: {:error, name, value, Map.delete(changes, @bound_key)}

  defp unbind(result, _fun), do: result

  defp with_setting(user_id, fun) do
    set_setting(user_id)
    result = fun.()
    if reset_after?(), do: set_setting("")
    result
  end

  # The sandbox keeps one outer transaction per test, so a released savepoint
  # would leave the setting behind; production transactions end for real.
  defp reset_after?, do: Application.get_env(:cash_lens, :sql_sandbox, false)

  defp set_setting(value) do
    SQL.query!(__MODULE__, "SELECT set_config($1, $2, true)", [
      @setting,
      to_string(value)
    ])

    :ok
  end
end
