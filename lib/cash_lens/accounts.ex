defmodule CashLens.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Accounts.Account

  @doc """
  Returns the list of accounts.
  """
  def list_accounts do
    Repo.all(Account)
  end

  @doc """
  Returns the list of active (non-closed) accounts.
  """
  def list_active_accounts do
    Repo.all(from a in Account, where: a.is_closed == false)
  end

  @doc """
  Calculates the total balance across all accounts.
  """
  def get_total_balance do
    Repo.aggregate(Account, :sum, :balance) || Decimal.new("0")
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account!(123)
      %Account{}

      iex> get_account!(456)
      ** (Ecto.NoResultsError)

  """
  def get_account!(id), do: Repo.get!(Account, id)

  @doc """
  Gets an account by its exact name.
  """
  def get_account_by_name(name) do
    Repo.get_by(Account, name: name)
  end

  @doc """
  Finds accounts matching a bank and name pair, case-insensitively.
  Returns a list so callers can distinguish 0, 1, or ambiguous (2+) matches.
  """
  def find_accounts_by_bank_and_name(bank, name) do
    b = bank |> String.trim() |> String.downcase()
    n = name |> String.trim() |> String.downcase()

    from(a in Account,
      where: fragment("lower(?)", a.bank) == ^b and fragment("lower(?)", a.name) == ^n
    )
    |> Repo.all()
  end

  @doc """
  Fetches multiple accounts by name in a single query. Returns a map of name => account.
  """
  def get_accounts_by_names(names) do
    from(a in Account, where: a.name in ^names)
    |> Repo.all()
    |> Map.new(fn a -> {a.name, a} end)
  end

  @doc """
  Creates a account.

  ## Examples

      iex> create_account(%{field: value})
      {:ok, %Account{}}

      iex> create_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a account.

  ## Examples

      iex> update_account(account, %{field: new_value})
      {:ok, %Account{}}

      iex> update_account(account, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a account.

  ## Examples

      iex> delete_account(account)
      {:ok, %Account{}}

      iex> delete_account(account)
      {:error, %Ecto.Changeset{}}

  """
  def delete_account(%Account{} = account) do
    Repo.transaction(fn ->
      Repo.delete_all(from b in CashLens.Accounting.Balance, where: b.account_id == ^account.id)

      Repo.delete_all(
        from t in CashLens.Transactions.Transaction, where: t.account_id == ^account.id
      )

      case Repo.delete(account) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, deleted} -> {:ok, deleted}
      {:error, changeset} -> {:error, changeset}
    end
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
