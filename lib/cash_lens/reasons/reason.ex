defmodule CashLens.Reasons.Reason do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reasons" do
    field :reason, :string
    field :refundable, :boolean, default: false
    field :ignore, :boolean, default: false

    belongs_to :category, CashLens.Categories.Category
    belongs_to :parent, CashLens.Reasons.Reason

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reason, attrs) do
    reason
    |> cast(attrs, [:reason, :category_id, :refundable, :ignore, :parent_id])
    |> validate_required([:reason])
    |> unique_constraint(:reason)
  end
end
