defmodule CashLens.Transactions.TransferRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transfer_rules" do
    field :label, :string
    field :description_patterns, {:array, :string}, default: []

    belongs_to :source_account, CashLens.Accounts.Account
    belongs_to :destination_account, CashLens.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transfer_rule, attrs) do
    transfer_rule
    |> cast(attrs, [:label, :description_patterns, :source_account_id, :destination_account_id])
    |> validate_required([:source_account_id, :destination_account_id])
    |> validate_description_patterns()
    |> validate_accounts_differ()
    |> foreign_key_constraint(:source_account_id)
    |> foreign_key_constraint(:destination_account_id)
    |> check_constraint(:source_account_id,
      name: :source_destination_differ,
      message: "source and destination accounts must differ"
    )
  end

  defp validate_description_patterns(changeset) do
    # Note: Ecto's {:array, :string} cast automatically filters out empty strings,
    # so we only need to check for the resulting empty list here.
    patterns = get_field(changeset, :description_patterns)

    if patterns == nil or patterns == [] do
      add_error(changeset, :description_patterns, "can't be blank")
    else
      changeset
    end
  end

  defp validate_accounts_differ(changeset) do
    source = get_field(changeset, :source_account_id)
    destination = get_field(changeset, :destination_account_id)

    if source && destination && source == destination do
      add_error(changeset, :destination_account_id, "must be different from source account")
    else
      changeset
    end
  end
end
