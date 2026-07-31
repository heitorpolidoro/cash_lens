defmodule CashLens.Pluggy.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pluggy_items" do
    field :item_id, :string
    field :label, :string

    has_many :account_links, CashLens.Pluggy.AccountLink, foreign_key: :pluggy_item_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:item_id, :label])
    |> validate_required([:item_id])
  end
end
