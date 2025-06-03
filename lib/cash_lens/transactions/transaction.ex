defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field(:date_time, :utc_datetime)
    field(:reason, :string)
    field(:amount, :decimal)
    field(:identifier, :string)
    belongs_to(:account, CashLens.Accounts.Account)
    belongs_to(:category, CashLens.Categories.Category)
    belongs_to(:user, CashLens.Users.User)

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:date_time, :reason, :amount, :identifier, :account_id, :category_id])
    |> validate_required([:date_time, :reason, :amount, :identifier])
  end
end
