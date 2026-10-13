defmodule CashLensWeb.UserConfirmationController do
  use CashLensWeb, :controller

  alias CashLens.Users
  alias CashLensWeb.UserRegistrationController

  @sent "If that email has an unconfirmed account, a new confirmation link is on its way."

  def new(conn, _params), do: render(conn, :new)

  # Same answer whether or not the email exists or is already confirmed.
  def create(conn, params) do
    with %{"user" => %{"email" => email}} when is_binary(email) <- params,
         %{} = user <- Users.get_user_by_email(email) do
      Users.deliver_confirmation_instructions(user, &UserRegistrationController.confirm_url/1)
    end

    conn |> put_flash(:info, @sent) |> redirect(to: ~p"/users/log_in")
  end

  def confirm(conn, %{"token" => token}) do
    case Users.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email confirmed. You can log in now.")
        |> redirect(to: ~p"/users/log_in")

      :error ->
        conn
        |> put_flash(:error, "The confirmation link is invalid or has expired.")
        |> redirect(to: ~p"/users/log_in")
    end
  end
end
