defmodule CashLensWeb.UserRegistrationController do
  use CashLensWeb, :controller

  alias CashLens.Users
  alias CashLens.Users.User

  def new(conn, _params) do
    render(conn, :new, changeset: Users.change_user_registration(%User{}))
  end

  def create(conn, %{"user" => user_params}) do
    case Users.register_user(user_params) do
      {:ok, user} ->
        Users.deliver_confirmation_instructions(user, &confirm_url/1)

        conn
        |> put_flash(:info, "Account created. Check your email to confirm it before logging in.")
        |> redirect(to: ~p"/users/log_in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end

  @doc false
  def confirm_url(token), do: CashLensWeb.Endpoint.url() <> ~p"/users/confirm/#{token}"
end
