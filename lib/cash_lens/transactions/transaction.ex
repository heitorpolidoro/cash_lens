defmodule CashLens.Transactions.Transaction do
  @moduledoc """
  Transaction model for MongoDB
  """

  defstruct [
    :_id,
    :date,
    :time,
    :raw_reason,
    :reason,
    :category,
    :amount,
    :full_line,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          _id: BSON.ObjectId.t() | nil,
          date: Date.t() | nil,
          time: Time.t() | nil,
          raw_reason: String.t() | nil,
          reason: String.t() | nil,
          category: String.t() | nil,
          amount: Decimal.t() | nil,
          full_line: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def new(attrs \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      _id: Map.get(attrs, :_id),
      date: Map.get(attrs, :date),
      time: Map.get(attrs, :time),
      raw_reason: Map.get(attrs, :raw_reason),
      reason: Map.get(attrs, :reason),
      category: Map.get(attrs, :category),
      amount: Map.get(attrs, :amount),
      full_line: Map.get(attrs, :full_line),
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end
end
