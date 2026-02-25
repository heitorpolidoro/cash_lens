defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transactions" do
    field :date, :date
    field :description, :string
    field :amount, :decimal
    field :category, :string
    field :account_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:date, :description, :amount, :category, :account_id])
    |> validate_required([:date, :description, :amount, :account_id])
  end
end
