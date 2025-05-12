defmodule CashLens.ReasonsToIgnore.ReasonToIgnore do
  use Ecto.Schema
  import Ecto.Changeset

  alias CashLens.Parsers

  schema "reasons_to_ignore" do
    field :reason, :string
    field :parser, Ecto.Enum, values: Parsers.available_parsers_slugs()

    timestamps()
  end

  @doc false
  def changeset(reasons_to_ignore, attrs) do
    reasons_to_ignore
    |> cast(attrs, [:reason, :parser])
    |> validate_required([:reason, :parser])
  end
end
