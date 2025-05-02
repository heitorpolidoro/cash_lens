defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :date, :date
    field :time, :time
    field :reason, :string
    field :category, :string
    field :amount, :decimal

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:date, :time, :reason, :category, :amount])
    |> validate_required([:date, :time, :reason, :category, :amount])
  end
end
