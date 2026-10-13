defmodule CashLens.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Ownership
  alias CashLens.Repo

  alias CashLens.Accounts.Account
  alias CashLens.Users.User

  @doc """
  Returns the list of the user's accounts.

  Pass `include_closed: false` to leave closed (archived) accounts out.
  """
  def list_accounts(%User{} = user, opts \\ []) do
    Account
    |> Ownership.scope(user)
    |> in_display_order()
    |> filter_closed(opts)
    |> Repo.all()
  end

  @doc """
  Returns the bank accounts and digital wallets (`is_credit_card: false`),
  in the order the user arranged.

  Pass `include_closed: false` to leave closed (archived) accounts out.
  """
  def list_bank_accounts(%User{} = user, opts \\ []) do
    from(a in Account, where: a.is_credit_card == false)
    |> Ownership.scope(user)
    |> in_display_order()
    |> filter_closed(opts)
    |> Repo.all()
  end

  @doc """
  Returns the credit-card accounts (`is_credit_card: true`), in the order the
  user arranged.

  Pass `include_closed: false` to leave closed (archived) accounts out.
  """
  def list_credit_cards(%User{} = user, opts \\ []) do
    from(a in Account, where: a.is_credit_card == true)
    |> Ownership.scope(user)
    |> in_display_order()
    |> filter_closed(opts)
    |> Repo.all()
  end

  # The order the user arranged, then everything never placed, by name. Name
  # last so a new account lands somewhere predictable instead of wherever
  # Postgres felt like putting it -- which is what every list did before there
  # was a position at all.
  defp in_display_order(query) do
    from a in query, order_by: [asc_nulls_last: a.position, asc: a.name]
  end

  @doc """
  Writes the given ids' order, as positions 0..n.

  Takes the whole list rather than "move this one up" so the caller's screen is
  the source of truth: the rows it is looking at, in the order it wants them.
  A per-account swap would have to guess what sits beside an account that was
  never placed, and two accounts could hold the same position forever.

  Accounts not named here keep whatever position they had, and ids that are not
  the user's accounts are skipped.
  """
  def reorder_accounts(%User{} = user, ids) when is_list(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, position} ->
        from(a in Account, where: a.id == ^id)
        |> Ownership.scope(user)
        |> Repo.update_all(set: [position: position, updated_at: now])
      end)
    end)

    :ok
  end

  @doc """
  The same list with one account moved one place towards `:up` or `:down`.

  Pure: it answers "what would the new order be", and `reorder_accounts/2`
  writes it. At either end the list comes back unchanged, so a button at the
  top of the list is a no-op rather than an error.
  """
  def move(accounts, account_id, direction) when direction in [:up, :down] do
    case Enum.find_index(accounts, &(&1.id == account_id)) do
      nil -> accounts
      index -> swap(accounts, index, target_index(index, direction, length(accounts)))
    end
  end

  defp target_index(index, :up, _length), do: index - 1
  defp target_index(index, :down, _length), do: index + 1

  defp swap(accounts, _index, target) when target < 0, do: accounts

  defp swap(accounts, index, target) do
    if target >= length(accounts) do
      accounts
    else
      moved = Enum.at(accounts, index)
      displaced = Enum.at(accounts, target)

      accounts
      |> List.replace_at(index, displaced)
      |> List.replace_at(target, moved)
    end
  end

  defp filter_closed(query, opts) do
    if Keyword.get(opts, :include_closed, true) do
      query
    else
      from a in query, where: a.is_closed == false
    end
  end

  @doc """
  Returns the list of active (non-closed) accounts.
  """
  def list_active_accounts(%User{} = user) do
    Account
    |> Ownership.scope(user)
    |> where([a], a.is_closed == false)
    |> Repo.all()
  end

  @doc """
  Calculates the total balance across all accounts.
  """
  def get_total_balance(%User{} = user) do
    Account
    |> Ownership.scope(user)
    |> Repo.aggregate(:sum, :balance) || Decimal.new("0")
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account!(user, 123)
      %Account{}

      iex> get_account!(user, 456)
      ** (Ecto.NoResultsError)

  """
  def get_account!(%User{} = user, id) do
    Account |> Ownership.scope(user) |> Repo.get!(id)
  end

  @doc """
  Gets an account by its exact name.
  """
  def get_account_by_name(%User{} = user, name) do
    Account |> Ownership.scope(user) |> Repo.get_by(name: name)
  end

  @doc """
  Finds accounts matching a bank and name pair, case-insensitively.
  Returns a list so callers can distinguish 0, 1, or ambiguous (2+) matches.
  """
  def find_accounts_by_bank_and_name(%User{} = user, bank, name) do
    b = bank |> String.trim() |> String.downcase()
    n = name |> String.trim() |> String.downcase()

    from(a in Account,
      where: fragment("lower(?)", a.bank) == ^b and fragment("lower(?)", a.name) == ^n
    )
    |> Ownership.scope(user)
    |> Repo.all()
  end

  @doc """
  Fetches multiple accounts by name in a single query. Returns a map of name => account.
  """
  def get_accounts_by_names(%User{} = user, names) do
    from(a in Account, where: a.name in ^names)
    |> Ownership.scope(user)
    |> Repo.all()
    |> Map.new(fn a -> {a.name, a} end)
  end

  @doc """
  Creates an account owned by `user`; a `user_id` in `attrs` is ignored.

  ## Examples

      iex> create_account(user, %{field: value})
      {:ok, %Account{}}

      iex> create_account(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_account(%User{} = user, attrs) do
    %Account{user_id: user.id}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates one of the user's accounts; `{:error, :not_found}` for anyone else's.

  ## Examples

      iex> update_account(user, account, %{field: new_value})
      {:ok, %Account{}}

      iex> update_account(user, account, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_account(%User{} = user, %Account{id: id}, attrs) do
    case fetch_owned(user, id) do
      nil ->
        {:error, :not_found}

      account ->
        account
        |> Account.changeset(attrs)
        |> Repo.update()
    end
  end

  defp fetch_owned(user, id), do: Account |> Ownership.scope(user) |> Repo.get(id)

  @doc """
  Deletes one of the user's accounts; `{:error, :not_found}` for anyone else's.

  ## Examples

      iex> delete_account(user, account)
      {:ok, %Account{}}

      iex> delete_account(user, account)
      {:error, %Ecto.Changeset{}}

  """
  def delete_account(%User{} = user, %Account{id: id}) do
    case fetch_owned(user, id) do
      nil -> {:error, :not_found}
      account -> do_delete_account(user, account)
    end
  end

  defp do_delete_account(user, account) do
    Repo.transaction(fn ->
      CashLens.Accounting.Balance
      |> Ownership.scope(user)
      |> where([b], b.account_id == ^account.id)
      |> Repo.delete_all()

      CashLens.Transactions.Transaction
      |> Ownership.scope(user)
      |> where([t], t.account_id == ^account.id)
      |> Repo.delete_all()

      case Repo.delete(account) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking account changes.

  ## Examples

      iex> change_account(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.changeset(account, attrs)
  end
end
