defmodule CashLens.Transfers.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transfers" do
    belongs_to :from, CashLens.Transactions.Transaction
    belongs_to :to, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:from_id, :to_id])
    |> foreign_key_constraint(:from_id)
    |> foreign_key_constraint(:to_id)
    |> unique_constraint([:from_id, :to_id])
    |> validate_different_transactions()
  end

  defp validate_different_transactions(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id != nil && to_id != nil && from_id == to_id do
      add_error(changeset, :to_id, "must be different from from_id")
    else
      changeset
    end
  end
end
