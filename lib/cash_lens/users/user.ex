defmodule CashLens.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:name, :string)
    field(:email, :string)
    field(:sub, :string)

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :email, :sub])
    |> validate_required([:name, :email, :sub])
    |> unique_constraint(:name)
    |> unique_constraint(:email)
    |> unique_constraint(:sub)
  end
end
