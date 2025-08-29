defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Transactions.Transaction
  alias CashLens.Accounts.Account
  alias CashLens.Categories.Category
  alias CashLens.ML.TransactionClassifier

  @doc """
  Returns the list of transactions.

  ## Examples

      iex> list_transactions()
      [%Transaction{}, ...]

  """
  def list_transactions do
    Transaction
    |> Repo.all()
    |> Repo.preload([:account, :category])
  end

  def filter_transactions(filter) do
    Transaction
    |> QueryBuilder.where([{:value, :lt, -1000}])
    |> Repo.all()
    |> Repo.preload([:account, :category])
  end

  @doc """
  Gets a single transaction.

  Raises `Ecto.NoResultsError` if the Transaction does not exist.

  ## Examples

      iex> get_transaction!(123)
      %Transaction{}

      iex> get_transaction!(456)
      ** (Ecto.NoResultsError)

  """
  def get_transaction!(id) do
    Transaction
    |> Repo.get!(id)
    |> Repo.preload([:account, :category])
  end

  @doc """
  Creates a transaction.

  ## Examples

      iex> create_transaction(%{field: value})
      {:ok, %Transaction{}}

      iex> create_transaction(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transaction(attrs \\ %{}) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} -> {:ok, Repo.preload(transaction, [:account, :category])}
      error -> error
    end
  end

  @doc """
  Updates a transaction.

  ## Examples

      iex> update_transaction(transaction, %{field: new_value})
      {:ok, %Transaction{}}

      iex> update_transaction(transaction, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_transaction(%Transaction{} = transaction, attrs) do
    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, transaction} -> {:ok, Repo.preload(transaction, [:account, :category])}
      error -> error
    end
  end

  @doc """
  Deletes a transaction.

  ## Examples

      iex> delete_transaction(transaction)
      {:ok, %Transaction{}}

      iex> delete_transaction(transaction)
      {:error, %Ecto.Changeset{}}

  """
  def delete_transaction(%Transaction{} = transaction) do
    Repo.delete(transaction)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking transaction changes.

  ## Examples

      iex> change_transaction(transaction)
      %Ecto.Changeset{data: %Transaction{}}

  """
  def change_transaction(%Transaction{} = transaction, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  @doc """
  Returns a list of accounts for select options.
  """
  def list_accounts_for_select do
    Repo.all(from a in Account, select: {a.name, a.id}, order_by: a.name)
  end

  @doc """
  Returns a list of categories for select options.
  """
  def list_categories_for_select do
    Repo.all(from c in Category, select: {c.name, c.id}, order_by: c.name)
  end

  @doc """
  Trains the transaction classification model using existing transaction data.

  Returns `:ok` if training was successful, or `{:error, reason}` if it failed.

  ## Examples

      iex> train_classification_model()
      {:ok, "Model saved successfully"}

      iex> train_classification_model()
      {:error, "No transactions with categories found for training"}

  """
  def train_classification_model do
    case TransactionClassifier.train_model() do
      {:ok, _message} = result ->
        # Reload the model in the worker after training
        CashLens.ML.ModelWorker.reload_model()
        result

      error ->
        error
    end
  end

  @doc """
  Predicts category for a transaction.

  Takes a transaction map or struct with at least :datetime, :value, and :reason fields.
  Returns `{:ok, %{category_id: id}}` if successful,
  or `{:error, reason}` if prediction failed.

  ## Examples

      iex> predict_transaction_attributes(%{datetime: ~U[2025-08-19 10:00:00Z], value: Decimal.new("123.45"), reason: "Grocery shopping"})
      {:ok, %{category_id: 1}}

      iex> predict_transaction_attributes(%{})
      {:error, "Transaction must have datetime, value, and reason fields"}

  """
  def predict_transaction_attributes(transaction) do
    TransactionClassifier.predict(transaction)
  end

  @doc """
  Creates a transaction with predicted category.

  If the transaction doesn't have a category_id set,
  it attempts to predict this value using the ML model.

  ## Examples

      iex> create_transaction_with_prediction(%{datetime: ~U[2025-08-19 10:00:00Z], value: Decimal.new("123.45"), reason: "Grocery shopping", account_id: 1})
      {:ok, %Transaction{}}

  """
  def create_transaction_with_prediction(attrs) do
    # Check if category_id is missing
    if is_nil(attrs[:category_id]) or is_nil(attrs["category_id"]) do
      case predict_transaction_attributes(attrs) do
        {:ok, %{category_id: category_id}} ->
          # Merge predictions with attrs
          attrs =
            attrs
            |> Map.put_new(:category_id, category_id)

          create_transaction(attrs)

        {:error, _reason} ->
          # Proceed without predictions
          create_transaction(attrs)
      end
    else
      # Category is already set, proceed normally
      create_transaction(attrs)
    end
  end
end
