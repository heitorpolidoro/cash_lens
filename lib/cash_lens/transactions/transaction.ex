defmodule CashLens.Transactions.Transaction do
  @moduledoc """
  Transaction model for MongoDB
  """

  alias CashLens.Accounts.Account

  defstruct [
    :_id,
    :account_id,
    :date,
    :time,
    :reason,
    :type,
    :category,
    :amount,
    :full_line,
    :inserted_at,
    :updated_at,
    :account
  ]

  @type t :: %__MODULE__{
          _id: BSON.ObjectId.t() | nil,
          account_id: BSON.ObjectId.t() | nil,
          date: Date.t() | nil,
          time: Time.t() | nil,
          reason: String.t() | nil,
          type: String.t() | nil,
          category: String.t() | nil,
          amount: Decimal.t() | nil,
          full_line: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          account: Account.t()
        }

  def new(attrs \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      _id: Map.get(attrs, :_id),
      account_id: Map.get(attrs, :account_id),
      date: Map.get(attrs, :date),
      time: Map.get(attrs, :time),
      reason: Map.get(attrs, :reason),
      type: Map.get(attrs, :type),
      category: Map.get(attrs, :category),
      amount: Map.get(attrs, :amount),
      full_line: Map.get(attrs, :full_line),
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end
end
