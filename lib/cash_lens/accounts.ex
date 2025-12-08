defmodule CashLens.Accounts do
  @moduledoc """
  Context for managing accounts
  """

  alias CashLens.Accounts.Account

  @collection "accounts"

  def list_accounts do
    Mongo.find(:mongo, @collection, %{})
    |> Enum.map(&document_to_struct/1)
  end

  def list_by_ids(ids) do
    Mongo.find(:mongo, @collection, %{_id: %{"$in": ids}})
    |> Enum.map(&document_to_struct/1)
  end

  def get_account(id) do
    case Mongo.find_one(:mongo, @collection, %{_id: BSON.ObjectId.decode!(id)}) do
      nil -> {:error, :not_found}
      doc -> {:ok, document_to_struct(doc)}
    end
  end

  defp document_to_struct(doc) do
    atomized =
      for {key, val} <- doc, into: %{} do
        atom_key = if is_binary(key), do: String.to_atom(key), else: key
        {atom_key, val}
      end

    struct(Account, atomized)
  end

  def create_account(attrs) do
    account = Account.new(attrs)

    doc =
      account
      |> Map.from_struct()
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Mongo.insert_one(:mongo, @collection, doc) do
      {:ok, %{inserted_id: id}} ->
        {:ok, %{account | _id: id}}

      error ->
        error
    end
  end

  def update_account(id, attrs) do
    updates = %{
      "$set" => Map.merge(attrs, %{updated_at: DateTime.utc_now()})
    }

    case Mongo.update_one(:mongo, @collection, %{_id: BSON.ObjectId.decode!(id)}, updates) do
      {:ok, %{matched_count: 1}} ->
        get_account(id)

      {:ok, %{matched_count: 0}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  def delete_account(id) do
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
  Ensure MongoDB indexes for the accounts collection exist.

  Creates a unique compound index on `{bank, name}` to prevent duplicate
  account names within the same bank. This function is idempotent and can be
  executed multiple times.
  """
  def ensure_indexes do
    indexes = [
      %{
        key: %{bank: 1, name: 1},
        name: "unique_bank_name",
        unique: true
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

  def full_name(%BSON.ObjectId{} = object_id) do
    BSON.ObjectId.encode!(object_id)
    |> get_account
    |> case do
      {:ok, account} ->
        full_name(account)

      _ ->
        "Unknown Account"
    end
  end

  def full_name(%Account{name: name, bank: bank}) do
    "#{bank} - #{name}"
  end
end
