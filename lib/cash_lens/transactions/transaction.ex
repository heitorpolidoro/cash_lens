defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :date, :date
    field :time, :time
    field :reason, :string
    field :category, :string
    field :amount, :decimal
    field :identifyer, :string
    belongs_to :account, CashLens.Accounts.Account

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:date, :time, :reason, :category, :amount, :identifyer])
    |> validate_required([:date, :reason, :amount, :identifyer])
  end
end
