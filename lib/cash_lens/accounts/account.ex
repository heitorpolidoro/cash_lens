defmodule CashLens.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "accounts" do
    field :name, :string
    field :bank_name, :string
    field :type, Ecto.Enum, values: [:checking, :credit_card, :investment]

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :bank_name, :type])
    |> validate_required([:name, :bank_name, :type])
  end
end
