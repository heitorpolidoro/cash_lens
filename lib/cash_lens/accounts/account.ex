defmodule CashLens.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types [:checking, :credit_card, :investment, :savings]

  schema "accounts" do
    field :name, :string
    field :type, :string
    field :bank_name, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :bank_name, :type])
    |> validate_required([:name, :bank_name, :type])
    |> unique_constraint([:name, :bank_name])
    |> validate_inclusion(:type, Enum.map(@valid_types, &to_string/1), message: "must be one of: #{inspect(@valid_types)}")
  end

  def valid_types() do
    @valid_types
  end
end
