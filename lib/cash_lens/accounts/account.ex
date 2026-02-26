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
    field :accepts_import, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :bank, :balance, :color, :icon, :accepts_import])
    |> validate_required([:name, :bank, :balance, :accepts_import])
  end
end
