defmodule CashLensWeb.AuthController do
  require Logger
  use CashLensWeb, :controller

  plug Ueberauth

  alias CashLens.Users

    def fetch_current_user(conn, _opts) do
    case get_session(conn, :current_user) do
      nil ->
        conn
        |> redirect(to: "/login")
        |> halt()
      user ->
        assign(conn, :current_user, user)
    end
  end

  def login(conn, _params) do
    conn
    |> assign(:version, Application.get_env(:cash_lens, :version))
    |>render(:login, layout: false)
  end

  # Handles the OAuth provider request
  def request(conn, _params) do
    # Here, Ueberauth takes care of redirecting the user to the Google OAuth provider
    redirect(conn, external: Ueberauth.Strategy.Helpers.callback_url(conn))
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    user = %{
      sub: auth.uid,
      email: auth.info.email,
      name: auth.info.name,
      picture: auth.info.image
    }
    if user.sub == Application.get_env(:cash_lens, :allowed_google_sub)  do
      Logger.info("User #{user.sub} logged in.")
      user = Map.merge(user, Users.fetch_user(user))

      conn
      |> put_flash(:info, "Successfully authenticated.")
      |> put_session(:current_user, user)
      |> redirect(to: "/")
    else
      conn
      |> redirect(to: "/unauthorized")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end

  def unauthorized(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:error, "You are not authorized to access this application.")
    |> redirect(to: "/login")
  end
end
