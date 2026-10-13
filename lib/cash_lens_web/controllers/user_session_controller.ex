defmodule CashLensWeb.UserSessionController do
  use CashLensWeb, :controller

  alias CashLens.Users
  alias CashLensWeb.UserAuth

  @invalid "Invalid email or password"

  def new(conn, _params) do
    render(conn, :new, error: nil, email: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Users.get_user_by_email_and_password(email, password) do
      nil ->
        # One generic message: never reveal whether the email exists.
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: @invalid, email: String.slice(email, 0, 160))

      user ->
        UserAuth.log_in_user(conn, user)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> render(:new, error: @invalid, email: nil)
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
