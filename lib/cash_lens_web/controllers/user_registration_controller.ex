defmodule CashLensWeb.UserRegistrationController do
  use CashLensWeb, :controller

  alias CashLens.Users
  alias CashLens.Users.User
  alias CashLensWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, changeset: Users.change_user_registration(%User{}))
  end

  def create(conn, %{"user" => user_params}) do
    case Users.register_user(user_params) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user, ~p"/users/pending")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
