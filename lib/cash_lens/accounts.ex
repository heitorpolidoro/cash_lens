defmodule CashLens.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Accounts.Account
  alias CashLens.Parsers

  def load_parser(accounts) when is_list(accounts) do
    accounts
    |> Enum.map(fn acc -> load_parser(acc) end)
  end

  def load_parser({:ok, account}) do
    {:ok, load_parser(account)}
  end

  def load_parser(account) do
    %{account | parser: Parsers.get_parser_by_slug(account.parser)}
  end

  @doc """
  Returns the list of accounts.

  ## Examples

      iex> list_accounts()
      [%Account{}, ...]

  """
  def list_accounts(user_id) do
    Account
    |> where([a], a.user_id == ^user_id)
    |> Repo.all()
    |> load_parser()
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
  def get_account!(id), do: Repo.get!(Account, id) |> load_parser()

  def get_account_by_name!(name) do
    Repo.one(from(a in Account, where: a.name == ^name)) |> load_parser()
  end

  @doc """
  Creates a account.

  ## Examples

      iex> create_account(%{field: value})
      {:ok, %Account{}}

      iex> create_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_account(attrs \\ %{}) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
    |> load_parser()
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
    |> load_parser()
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
    Repo.delete(account)
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

  @doc """
  Returns a list of account names from all accounts.
  """
  def list_account_options do
    Account
    |> Repo.all()
    |> Enum.map(fn a -> "#{a.bank_name} - #{a.name}" end)
    |> Enum.uniq()
  end
end
