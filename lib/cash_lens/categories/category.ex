defmodule CashLens.Categories.Category do
  use Ecto.Schema
  import Ecto.Changeset

  alias CashLens.Utils

  @available_types ["One-time", "Annual", "Monthly"]

  def available_types(), do: @available_types

  schema "categories" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: Utils.to_atoms(@available_types))
    has_many(:transactions, CashLens.Transactions.Transaction)
    belongs_to(:parent, CashLens.Categories.Category, foreign_key: :parent_id)

    timestamps()
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :type, :parent_id])
    |> validate_required([:name, :type])
  end
end
