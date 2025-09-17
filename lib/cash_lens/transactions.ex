# TODO Review
defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """
  require Logger

  import Ecto.Query
  alias CashLens.Repo

  alias CashLens.Transactions.Transaction
  alias CashLens.Categories.Category
  alias CashLens.Categories
  alias CashLens.ML.TransactionClassifier
  alias CashLens.Transfers
  alias CashLens.AutomaticTransfers

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

  # TODO
  def find_transactions(filters, group_by \\ nil, preload \\ false) do
    transactions = QueryBuilder.where(Transaction, filters)

    #    if is_nil(group_by) do
    #      QueryBuilder.group_by(transactions, group_by)
    #    else
    #      transactions
    #    end

    if preload do
      QueryBuilder.preload(transactions, [:account, :category])
    else
      transactions
    end
    |> Repo.all()
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

  defp do_create_transaction(attrs) do
  end

  #  defp create_transaction2(%{category: %{name: "Transfer"}} = attrs) do
  #    with {:ok, transaction} <- do_create_transaction(attrs) do
  #      case find_transactions({:amount, Decimal.negate(transaction.amount)}) do
  #        [] ->
  #          if account = AutomaticTransfers.find_automatic_transfer_account_to!(transaction.account) do
  #            # TODO treat then return error
  #            {:ok, other_transaction} =
  #              do_create_transaction(%{
  #                Map.from_struct(transaction)
  #                | account_id: account.id,
  #                  amount: Decimal.negate(transaction.amount)
  #              })
  #
  #            Transfers.create_transfer_from_transactions(transaction, other_transaction)
  #          else
  #            Transfers.create_transfer_from_transactions(transaction, nil)
  #          end
  #
  #          Logger.info("Transfer created: #{inspect(transaction)}")
  #
  #        [transfer_transaction] ->
  #          Transfers.update_transfer_from_transactions(transfer_transaction, transaction)
  #
  #        _transfer_transactions ->
  #          raise "Multiple transfer transactions found"
  #      end
  #
  #      {:ok, transaction}
  #    else
  #      {:error, reason} ->
  #        {:error, reason}
  #    end
  #  end

  def create_transaction(attrs) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} -> {:ok, Repo.preload(transaction, [:account, :category])}
      error -> error
    end
    |> broadcast_transaction_change(:transaction_created)
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
    |> broadcast_transaction_change(:transaction_update)
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
    TransactionClassifier.train_model()
  end

  def set_category_with_prediction(transactions) when is_list(transactions) do
    Enum.map(transactions, &set_category_with_prediction/1)
  end

  def set_category_with_prediction(transaction) do
    case TransactionClassifier.predict(transaction) do
      {:ok, %{category_id: category_id}} ->
        transaction
        |> Map.put(:category, Categories.get_category!(category_id))

      {:error, reason} ->
        Logger.error(
          "Prediction failed for transaction: #{inspect(transaction)}\n#{inspect(reason)}"
        )

        # If prediction fails, return transaction without predictions
        transaction
    end
  end

  def list_transactions_grouped_by_account(account, year, month) do
    # Create start and end dates for the month
    start_date = DateTime.new!(Date.new!(year, month, 1), Time.new!(0, 0, 0), "Etc/UTC")

    end_date =
      Date.new!(year, month, 1)
      |> Date.end_of_month()
      |> DateTime.new!(Time.new!(23, 59, 59), "Etc/UTC")

    from(t in Transaction,
      where: t.datetime >= ^start_date and t.datetime <= ^end_date and t.account == ^account,
      preload: [:account, :category]
    )
    |> Repo.all()
  end

  defp broadcast_transaction_change({:ok, transaction} = result, event) do
    Logger.debug("Broadcasting transaction change event: #{inspect(event)}")

    Phoenix.PubSub.broadcast(
      CashLens.PubSub,
      "transaction_updates",
      {event, transaction}
    )

    result
  end

  defp broadcast_transaction_change({:error, _} = error, _event), do: error
end
