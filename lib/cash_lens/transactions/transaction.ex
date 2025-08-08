defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :datetime, :utc_datetime
    field :value, :decimal
    field :reason, :string
    field :refundable, :boolean, default: false

    belongs_to :account, CashLens.Accounts.Account
    belongs_to :category, CashLens.Categories.Category

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:datetime, :value, :reason, :refundable, :account_id, :category_id])
    |> validate_required([:datetime, :value, :account_id])
    |> validate_number(:value, greater_than_or_equal_to: -999_999_999.99, less_than_or_equal_to: 999_999_999.99)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:category_id)
  end
end
