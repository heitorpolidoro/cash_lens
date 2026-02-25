defmodule CashLens.Accounting.Balance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "balances" do
    field :year, :integer
    field :month, :integer
    field :initial_balance, :decimal
    field :income, :decimal
    field :expenses, :decimal
    field :balance, :decimal
    field :final_balance, :decimal
    belongs_to :account, CashLens.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:year, :month, :initial_balance, :income, :expenses, :balance, :final_balance, :account_id])
    |> validate_required([:year, :month, :initial_balance, :income, :expenses, :balance, :final_balance, :account_id])
  end
end
