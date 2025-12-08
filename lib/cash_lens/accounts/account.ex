defmodule CashLens.Accounts.Account do
  @moduledoc """
  Account model for MongoDB
  """

  @valid_types [:checking, :credit_card, :investment, :savings]

  defstruct [
    :_id,
    :bank,
    :name,
    :type,
    :inserted_at,
    :updated_at
  ]

  @type account_type :: :checking | :credit_card | :investment | :savings

  @type t :: %__MODULE__{
          _id: BSON.ObjectId.t() | nil,
          bank: String.t() | nil,
          name: String.t() | nil,
          type: account_type() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def new(attrs \\ %{}) do
    now = DateTime.utc_now()
    account_type = Map.get(attrs, :type)

    if account_type && account_type not in @valid_types do
      raise ArgumentError, "Invalid account type. Must be one of: #{inspect(@valid_types)}"
    end

    %__MODULE__{
      _id: Map.get(attrs, :_id),
      bank: Map.get(attrs, :bank),
      name: Map.get(attrs, :name),
      type: account_type,
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  def valid_types, do: @valid_types
end
