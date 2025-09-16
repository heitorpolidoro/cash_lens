defmodule CashLens.Balances.Balance do
  use Ecto.Schema
  import Ecto.Changeset

  alias CashLens.Accounts.Account

  schema "balances" do
    field :month, :date
    field :starting_value, :decimal
    field :total_in, :decimal
    field :total_out, :decimal
    field :balance, :decimal
    field :interest, :decimal
    field :final_value, :decimal

    belongs_to :account, Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [
      :month,
      :account_id,
      :starting_value,
      :total_in,
      :total_out,
      :balance,
      :interest,
      :final_value
    ])
    |> validate_required([:month, :account_id])
    |> foreign_key_constraint(:account_id)
    |> unique_constraint([:account_id, :month], name: :unique_account_month)
  end
end
