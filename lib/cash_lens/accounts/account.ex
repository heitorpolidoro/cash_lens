defmodule CashLens.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "accounts" do
    field :name, :string
    field :bank, :string
    field :balance, :decimal, default: 0
    field :color, :string
    field :icon, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :bank, :balance, :color, :icon])
    |> validate_required([:name, :bank, :balance])
  end
end
