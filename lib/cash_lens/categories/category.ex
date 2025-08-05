defmodule CashLens.Categories.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :fixed, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :fixed])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
