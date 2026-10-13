defmodule CashLensWeb.UserResetPasswordController do
  use CashLensWeb, :controller

  alias CashLens.Users

  plug :load_user when action in [:edit, :update]

  def new(conn, _params), do: render(conn, :new)

  # Same answer whether or not the email exists.
  def create(conn, params) do
    with %{"user" => %{"email" => email}} when is_binary(email) <- params,
         %{} = user <- Users.get_user_by_email(email) do
      Users.deliver_reset_password_instructions(user, &reset_url/1)
    end

    conn
    |> put_flash(:info, "If that email has an account, a password reset link is on its way.")
    |> redirect(to: ~p"/users/log_in")
  end

  def edit(conn, _params) do
    render(conn, :edit, changeset: Users.change_user_password(conn.assigns.user))
  end

  def update(conn, params) do
    user_params = Map.get(params, "user", %{})

    case Users.reset_user_password(conn.assigns.user, user_params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Password reset. Log in with the new password.")
        |> redirect(to: ~p"/users/log_in")

      {:error, changeset} ->
        render(conn, :edit, changeset: changeset)
    end
  end

  defp reset_url(token), do: CashLensWeb.Endpoint.url() <> ~p"/users/reset_password/#{token}"

  defp load_user(conn, _opts) do
    if user = Users.get_user_by_reset_password_token(conn.params["token"]) do
      assign(conn, :user, user)
    else
      conn
      |> put_flash(:error, "The reset link is invalid or has expired.")
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end
end
