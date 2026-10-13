defmodule CashLens.Audit.LoginAttempt do
  @moduledoc "One login attempt, successful or not. Never holds a password."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "login_attempts" do
    field :email, :string
    field :success, :boolean
    field :ip, :string
    belongs_to :user, CashLens.Users.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
