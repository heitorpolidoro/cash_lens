defmodule CashLens.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  alias CashLens.Parsers
  alias CashLens.Utils

  @available_types ["Checking", "Credit Card", "Investment"]

  def available_types(), do: @available_types

  schema "accounts" do
    field(:name, :string)
    field(:bank_name, :string)
    field(:type, Ecto.Enum, values: Utils.to_atoms(@available_types))
    field(:parser, Ecto.Enum, values: Parsers.available_parsers_slugs())
    belongs_to(:user, CashLens.Users.User)

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :bank_name, :type, :parser, :user_id])
    |> validate_required([:name, :bank_name, :type, :parser, :user_id])
  end
end
