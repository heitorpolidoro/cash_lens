defmodule CashLens.Forecast.RecurringItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recurring_items" do
    belongs_to :category, CashLens.Categories.Category
    field :label, :string
    field :day_of_month, :integer
    field :amount, :decimal
    field :active, :boolean, default: true
    field :manually_edited, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(recurring_item, attrs) do
    recurring_item
    |> cast(attrs, [:category_id, :label, :day_of_month, :amount, :active, :manually_edited])
    |> validate_required([:category_id, :label, :day_of_month, :amount])
    |> validate_number(:day_of_month, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_amount_not_zero()
    |> unique_constraint(:category_id)
  end

  defp validate_amount_not_zero(changeset) do
    case get_field(changeset, :amount) do
      nil ->
        changeset

      amount ->
        if Decimal.equal?(amount, 0) do
          add_error(changeset, :amount, "não pode ser zero")
        else
          changeset
        end
    end
  end
end
