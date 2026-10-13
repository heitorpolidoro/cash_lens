defmodule CashLensWeb.UserSessionController do
  use CashLensWeb, :controller

  alias CashLens.Audit
  alias CashLens.Users
  alias CashLens.Users.User
  alias CashLensWeb.Plugs.RateLimit
  alias CashLensWeb.UserAuth

  @invalid "Invalid email or password"
  @unconfirmed "Confirm your email before logging in. Check your inbox or request a new link."

  def new(conn, _params) do
    render(conn, :new, error: nil, email: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    user = Users.get_user_by_email(email)
    password_ok? = User.valid_password?(user, password)
    confirmed? = password_ok? and User.confirmed?(user)

    Audit.record_login_attempt(user, email, confirmed?, RateLimit.client_ip(conn))

    cond do
      confirmed? ->
        UserAuth.log_in_user(conn, user)

      # Said only to someone who proved they know the password, so it does not
      # reveal which emails exist.
      password_ok? ->
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: @unconfirmed, email: String.slice(email, 0, 160))

      true ->
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: @invalid, email: String.slice(email, 0, 160))
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
