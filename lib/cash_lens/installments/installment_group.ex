defmodule CashLens.Installments.InstallmentGroup do
  @moduledoc """
  A long-term commitment tracked across several months.

  Historically this schema only modelled credit-card instalment purchases
  ("parcelas"). It now also covers `"financing"` (long-term amortised debt) and
  `"consorcio"` (a Brazilian pooled-purchase plan with a credit letter and a
  contemplation status). `commitment_type` defaults to `"credit_card"`, so every
  row created before the commitment types were introduced keeps behaving exactly
  as a credit-card commitment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @commitment_types ~w(credit_card financing consorcio)

  @doc "The supported commitment modalities, in display order."
  def commitment_types, do: @commitment_types
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "installment_groups" do
    field :description_pattern, :string
    field :total_amount, :decimal
    field :installments, :integer
    field :start_date, :date
    field :commitment_type, :string, default: "credit_card"
    field :institution, :string
    field :interest_rate, :decimal
    field :credit_letter_amount, :decimal
    field :is_contemplated, :boolean, default: false
    field :contemplated_at, :date
    field :installment_amount, :decimal, virtual: true

    # How many parcels the contract has already billed. Never stored: it only
    # exists so the form can derive `start_date` backwards from today, because
    # a statement shows the parcels it imported, not the ones paid before that.
    field :paid_installments, :integer, virtual: true

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
      :installment_amount,
      :commitment_type,
      :institution,
      :interest_rate,
      :credit_letter_amount,
      :is_contemplated,
      :contemplated_at,
      :paid_installments
    ])
    |> validate_required([:description_pattern, :installments, :start_date])
    |> validate_number(:installments, greater_than: 1)
    |> validate_number(:paid_installments, greater_than_or_equal_to: 0)
    |> validate_paid_within_term()
    |> validate_inclusion(:commitment_type, @commitment_types)
    |> maybe_calculate_total_amount()
    |> unique_constraint(:description_pattern)
  end

  defp validate_paid_within_term(changeset) do
    paid = get_field(changeset, :paid_installments)
    total = get_field(changeset, :installments)

    if is_integer(paid) and is_integer(total) and paid > total do
      add_error(changeset, :paid_installments, "não pode ser maior que o total de parcelas")
    else
      changeset
    end
  end

  defp maybe_calculate_total_amount(changeset) do
    if changeset.valid? do
      total_amount = get_field(changeset, :total_amount)
      installment_amount = get_field(changeset, :installment_amount)
      installments = get_field(changeset, :installments)

      cond do
        # The parcel wins over a total already on the changeset. The form renders
        # `total_amount` as an input, so a total derived here comes straight back
        # as user input on the next keystroke — and a total derived while the term
        # read "6" on the way to "60" would otherwise be frozen, leaving a parcel
        # ten times too small.
        not is_nil(installment_amount) and not is_nil(installments) ->
          calculated_total = Decimal.mult(installment_amount, installments)
          put_change(changeset, :total_amount, calculated_total)

        not is_nil(total_amount) ->
          changeset

        true ->
          changeset
      end
    else
      changeset
    end
  end
end
