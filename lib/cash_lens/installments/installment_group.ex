defmodule CashLens.Installments.InstallmentGroup do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "installment_groups" do
    field :description_pattern, :string
    field :total_amount, :decimal
    field :installments, :integer
    field :start_date, :date
    field :installment_amount, :decimal, virtual: true

    has_many :transactions, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(installment_group, attrs) do
    installment_group
    |> cast(attrs, [
      :description_pattern,
      :total_amount,
      :installments,
      :start_date,
      :installment_amount
    ])
    |> validate_required([:description_pattern, :installments, :start_date])
    |> validate_number(:installments, greater_than: 1)
    |> maybe_calculate_total_amount()
    |> unique_constraint(:description_pattern)
  end

  defp maybe_calculate_total_amount(changeset) do
    if changeset.valid? do
      total_amount = get_field(changeset, :total_amount)
      installment_amount = get_field(changeset, :installment_amount)
      installments = get_field(changeset, :installments)

      cond do
        not is_nil(total_amount) ->
          changeset

        not is_nil(installment_amount) and not is_nil(installments) ->
          calculated_total = Decimal.mult(installment_amount, installments)
          put_change(changeset, :total_amount, calculated_total)

        true ->
          changeset
      end
    else
      changeset
    end
  end
end
