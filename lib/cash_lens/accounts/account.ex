defmodule CashLens.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "accounts" do
    field :name, :string
    field :bank, :string
    field :balance, :decimal, default: 0
    field :color, :string
    field :icon, :string
    field :accepts_import, :boolean, default: true
    field :parser_type, :string
    field :is_closed, :boolean, default: false
    field :is_credit_card, :boolean, default: false
    field :closing_day, :integer
    field :due_day, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :bank,
      :balance,
      :color,
      :icon,
      :accepts_import,
      :parser_type,
      :is_closed,
      :is_credit_card,
      :closing_day,
      :due_day
    ])
    |> validate_required([:name, :bank, :balance, :accepts_import, :is_closed])
    |> validate_inclusion(:closing_day, 1..31)
    |> validate_inclusion(:due_day, 1..31)
  end
end
