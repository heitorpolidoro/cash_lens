defmodule CashLens.Transactions do
  @moduledoc """
  Context for managing transactions
  """

  alias CashLens.Transactions.Transaction

  @collection "transactions"

  def list_transactions do
    Mongo.find(:mongo, @collection, %{})
    |> Enum.map(&document_to_struct/1)
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
        error
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
        error
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

  def create_sample_transactions do
    samples = [
      %{
        date: ~D[2024-01-15],
        time: "10:30:00",
        raw_reason: "COMPRA CARTAO **** 1234 SUPERMERCADO ABC",
        reason: "Supermercado ABC",
        category: "Alimentação",
        amount: Decimal.new("-150.75"),
        full_line: "15/01/2024 10:30 COMPRA CARTAO **** 1234 SUPERMERCADO ABC -150,75"
      },
      %{
        date: ~D[2024-01-16],
        time: "14:20:00",
        raw_reason: "PIX RECEBIDO JOAO SILVA",
        reason: "PIX João Silva",
        category: "Transferência",
        amount: Decimal.new("500.00"),
        full_line: "16/01/2024 14:20 PIX RECEBIDO JOAO SILVA +500,00"
      },
      %{
        date: ~D[2024-01-17],
        time: "09:15:00",
        raw_reason: "DEBITO AUTOMATICO ENERGIA ELETRICA",
        reason: "Conta de Luz",
        category: "Utilidades",
        amount: Decimal.new("-89.32"),
        full_line: "17/01/2024 09:15 DEBITO AUTOMATICO ENERGIA ELETRICA -89,32"
      },
      %{
        date: ~D[2024-01-18],
        time: "16:45:00",
        raw_reason: "COMPRA CARTAO **** 5678 POSTO SHELL",
        reason: "Posto Shell",
        category: "Combustível",
        amount: Decimal.new("-75.00"),
        full_line: "18/01/2024 16:45 COMPRA CARTAO **** 5678 POSTO SHELL -75,00"
      },
      %{
        date: ~D[2024-01-19],
        time: "11:00:00",
        raw_reason: "TED RECEBIDO EMPRESA XYZ LTDA",
        reason: "Salário Empresa XYZ",
        category: "Salário",
        amount: Decimal.new("3500.00"),
        full_line: "19/01/2024 11:00 TED RECEBIDO EMPRESA XYZ LTDA +3500,00"
      }
    ]

    Enum.map(samples, &create_transaction/1)
  end
end
