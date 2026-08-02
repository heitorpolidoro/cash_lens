defmodule CashLens.Pluggy.AccountLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pluggy_account_links" do
    field :pluggy_account_id, :string
    field :pluggy_account_name, :string
    field :pluggy_account_type, :string
    field :pluggy_balance, :decimal
    field :last_synced_at, :utc_datetime

    belongs_to :pluggy_item, CashLens.Pluggy.Item
    belongs_to :account, CashLens.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account_link, attrs) do
    account_link
    |> cast(attrs, [
      :pluggy_item_id,
      :pluggy_account_id,
      :pluggy_account_name,
      :pluggy_account_type,
      :pluggy_balance,
      :account_id,
      :last_synced_at
    ])
    |> validate_required([:pluggy_item_id, :pluggy_account_id])
    |> unique_constraint([:pluggy_item_id, :pluggy_account_id])
    |> foreign_key_constraint(:pluggy_item_id)
    |> foreign_key_constraint(:account_id)
  end
end
