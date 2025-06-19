defmodule CashLens.Categories.Category do
  use Ecto.Schema
  import Ecto.Changeset

  alias CashLens.Utils

  @available_types ["One-time", "Annual", "Monthly"]

  def available_types(), do: @available_types

  schema "categories" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: Utils.to_atoms(@available_types))

    belongs_to(:parent, CashLens.Categories.Category, foreign_key: :parent_id)
    belongs_to(:user, CashLens.Users.User)

    has_many(:transactions, CashLens.Transactions.Transaction)

    timestamps()
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :type, :parent_id, :user_id])
    |> validate_required([:name, :type, :user_id])
  end
end
