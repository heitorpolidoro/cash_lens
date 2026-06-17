defmodule CashLens.Transactions.RejectedReimbursementPair do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rejected_reimbursement_pairs" do
    belongs_to :transaction_a, CashLens.Transactions.Transaction
    belongs_to :transaction_b, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(rejected_pair, attrs) do
    rejected_pair
    |> cast(attrs, [:transaction_a_id, :transaction_b_id])
    |> validate_required([:transaction_a_id, :transaction_b_id])
    # Enforce order: transaction_a_id < transaction_b_id
    |> sort_ids()
    |> unique_constraint([:transaction_a_id, :transaction_b_id],
      name: :rejected_reimbursement_pairs_transaction_a_id_transaction_b_id_
    )
  end

  defp sort_ids(changeset) do
    id_a = get_field(changeset, :transaction_a_id)
    id_b = get_field(changeset, :transaction_b_id)

    if id_a && id_b && id_a > id_b do
      changeset
      |> put_change(:transaction_a_id, id_b)
      |> put_change(:transaction_b_id, id_a)
    else
      changeset
    end
  end
end
