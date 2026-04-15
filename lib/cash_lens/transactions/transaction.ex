defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transactions" do
    field :date, :date
    field :time, :time
    field :description, :string
    field :amount, :decimal
    field :transfer_key, Ecto.UUID
    field :reimbursement_status, :string
    field :reimbursement_link_key, Ecto.UUID
    field :fingerprint, :string
    belongs_to :account, CashLens.Accounts.Account
    belongs_to :category, CashLens.Categories.Category

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:date, :time, :description, :amount, :category_id, :account_id, :transfer_key, :reimbursement_status, :reimbursement_link_key])
    |> validate_required([:date, :description, :amount, :account_id])
    |> generate_fingerprint()
    |> unique_constraint(:fingerprint)
  end

  defp generate_fingerprint(changeset) do
    date = get_field(changeset, :date)
    time = get_field(changeset, :time)
    desc = get_field(changeset, :description)
    amount = get_field(changeset, :amount)
    account_id = get_field(changeset, :account_id)

    if date && desc && amount && account_id do
      # Create a unique string representing this transaction
      # Include time in the string if it exists
      time_str = if time, do: Time.to_string(time), else: ""
      
      # Ensure binary_id is treated as a string for consistent interpolation
      account_id_str = case account_id do
        <<_::128>> -> Ecto.UUID.load!(account_id)
        _ -> account_id
      end

      raw_string = "#{account_id_str}|#{date}|#{time_str}|#{Decimal.to_string(amount)}|#{String.trim(desc)}"
      
      # Hash the string to create a compact fingerprint
      hash = :crypto.hash(:sha256, raw_string) |> Base.encode16()
      
      put_change(changeset, :fingerprint, hash)
    else
      changeset
    end
  end
end
