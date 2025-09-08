defmodule CashLens.AutomaticTransfers.AutomaticTransfer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "automatic_transfers" do
    belongs_to :from, CashLens.Accounts.Account
    belongs_to :to, CashLens.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:from_id, :to_id])
    |> foreign_key_constraint(:from_id)
    |> foreign_key_constraint(:to_id)
    |> unique_constraint([:from_id, :to_id])
    |> validate_different_accounts()
  end

  defp validate_different_accounts(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id != nil && to_id != nil && from_id == to_id do
      add_error(changeset, :to_id, "must be different from from_id")
    else
      changeset
    end
  end
end
