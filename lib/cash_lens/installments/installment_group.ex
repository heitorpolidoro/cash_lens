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

    has_many :transactions, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(installment_group, attrs) do
    installment_group
    |> cast(attrs, [:description_pattern, :total_amount, :installments, :start_date])
    |> validate_required([:description_pattern, :installments, :start_date])
    |> validate_number(:installments, greater_than: 1)
    |> unique_constraint(:description_pattern)
  end
end
