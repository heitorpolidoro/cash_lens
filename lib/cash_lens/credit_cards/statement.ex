defmodule CashLens.CreditCards.Statement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_card_statements" do
    field :competencia, :date
    field :due_date, :date
    field :total_a_pagar, :decimal
    field :source_file, :string

    belongs_to :account, CashLens.Accounts.Account
    belongs_to :payment_transaction, CashLens.Transactions.Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(statement, attrs) do
    statement
    |> cast(attrs, [
      :id,
      :account_id,
      :competencia,
      :due_date,
      :total_a_pagar,
      :source_file,
      :payment_transaction_id
    ])
    |> validate_required([:account_id])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:payment_transaction_id)
  end
end
