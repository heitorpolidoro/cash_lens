defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  use QueryBuilder
  import Ecto.Changeset

  schema "transactions" do
    field :datetime, :utc_datetime
    field :amount, :decimal
    field :reason, :string
    field :refundable, :boolean, default: false

    belongs_to :account, CashLens.Accounts.Account
    belongs_to :category, CashLens.Categories.Category

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:datetime, :amount, :reason, :refundable, :account_id, :category_id])
    |> validate_required([:datetime, :amount, :account_id, :category_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:category_id)
  end
end
