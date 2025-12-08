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
end
