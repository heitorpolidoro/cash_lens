defmodule CashLens.Transactions do
  @moduledoc """
  Context for managing transactions
  """

  alias CashLens.Transactions.Transaction

  @collection "transactions"

  def list_transactions do
    Mongo.find(:mongo, @collection, %{})
    |> Enum.map(&document_to_struct/1)
    |> preload_accounts
  end

  def get_transaction(id) do
    case Mongo.find_one(:mongo, @collection, %{_id: BSON.ObjectId.decode!(id)}) do
      nil -> {:error, :not_found}
      doc -> {:ok, document_to_struct(doc)}
    end
  end

  defp document_to_struct(doc) do
    # Convert string keys to atom keys for struct
    atomized =
      for {key, val} <- doc, into: %{} do
        atom_key = if is_binary(key), do: String.to_atom(key), else: key
        #      val = if atom_key == :amount, do: Decimal.from_float(val), else: val
        {atom_key, val}
      end

    struct(Transaction, atomized)
  end

  def create_transaction(attrs) do
    transaction = Transaction.new(attrs)

    doc =
      transaction
      |> Map.from_struct()
      # Remove nil values including _id: nil
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Mongo.insert_one(:mongo, @collection, doc) do
      {:ok, %{inserted_id: id}} ->
        {:ok, %{transaction | _id: id}}

      error ->
        map_mongo_error(error)
    end
  end

  def create_transactions(attrs_list) do
    transactions =
      attrs_list
      |> Enum.map(&Transaction.new/1)

    docs =
      transactions
      |> Enum.map(fn transaction ->
        transaction
        |> Map.from_struct()
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      end)

    case Mongo.insert_many(:mongo, @collection, docs) do
      {:ok, %{inserted_ids: ids}} ->
        Enum.zip(transactions, ids)
        |> Enum.map(fn {transaction, id} ->
          %{transaction | _id: id}
        end)

        {:ok, transactions}

      error ->
        map_mongo_error(error)
    end
  end

  def update_transaction(id, attrs) do
    updates = %{
      "$set" => Map.merge(attrs, %{updated_at: DateTime.utc_now()})
    }

    case Mongo.update_one(:mongo, @collection, %{_id: BSON.ObjectId.decode!(id)}, updates) do
      {:ok, %{matched_count: 1}} ->
        get_transaction(id)

      {:ok, %{matched_count: 0}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  def delete_transaction(id) do
    case Mongo.delete_one(:mongo, @collection, %{_id: BSON.ObjectId.decode!(id)}) do
      {:ok, %{deleted_count: 1}} ->
        :ok

      {:ok, %{deleted_count: 0}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc """
  Ensure MongoDB indexes for the transactions collection exist.

  Currently creates a unique index on `full_line` to prevent duplicates.
  This function is idempotent and can be executed multiple times.
  """
  def ensure_indexes do
    indexes = [
      %{
        key: %{full_line: 1},
        name: "unique_full_line",
        unique: true
      },
      %{
        key: %{account_id: 1},
        name: "idx_account_id",
        unique: false
      }
    ]

    # Best-effort index creation; log errors but don't crash app startup
    case Mongo.create_indexes(:mongo, @collection, indexes) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Failed to create indexes for #{@collection}: #{inspect(reason)}")
        :ok
    end
  end

  def preload_accounts(transactions) when is_list(transactions) do
    accounts =
      transactions |> Enum.map(& &1.account_id) |> Enum.uniq() |> CashLens.Accounts.list_by_ids()

    Enum.map(transactions, fn transaction ->
      account_id = transaction.account_id
      acc = Enum.find(accounts, &(&1._id == account_id))
      %{transaction | account: acc}
    end)
  end

  defp map_mongo_error({:error, %Mongo.WriteError{write_errors: errors}}) do
    dup? = Enum.any?(errors, fn e -> Map.get(e, "code") == 11000 end)

    if dup? do
      {:error, :duplicate_full_line}
    else
      {:error, %Mongo.WriteError{write_errors: errors}}
    end
  end

  defp map_mongo_error(other), do: other
end
