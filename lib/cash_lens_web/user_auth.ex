defmodule CashLensWeb.UserAuth do
  @moduledoc """
  Session handling and the plugs that gate the app: a visitor must be logged in
  (`require_authenticated_user`) and the operator must have enabled the account
  (`require_enabled_user`). The user is re-read from the database on every
  request, so enabling or deleting a user takes effect without re-login.
  """
  use CashLensWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias CashLens.Users

  def log_in_user(conn, user, to \\ "/") do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_session(:session_nonce, user.session_nonce)
    |> redirect(to: to)
  end

  def log_out_user(conn) do
    if user = conn.assigns[:current_user], do: Users.rotate_session_nonce(user)

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/users/log_in")
  end

  defp renew_session(conn) do
    delete_csrf_token()
    conn |> configure_session(renew: true) |> clear_session()
  end

  def fetch_current_user(conn, _opts) do
    user = session_user(get_session(conn, :user_id), get_session(conn, :session_nonce))
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> redirect(to: ~p"/users/log_in") |> halt()
    end
  end

  def require_enabled_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %{enabled: true} -> conn
      _ -> conn |> redirect(to: ~p"/users/pending") |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  @doc "Session-based gate for the JSON API: 401 instead of a redirect."
  def require_enabled_user_api(conn, _opts) do
    conn = fetch_session(conn)

    case session_user(get_session(conn, :user_id), get_session(conn, :session_nonce)) do
      %{enabled: true} = user ->
        assign(conn, :current_user, user)

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "Unauthorized"}})
        |> halt()
    end
  end

  @doc "LiveView hook: re-checks the user on every mount, including reconnects."
  def on_mount(:require_enabled_user, _params, session, socket) do
    case session_user(session["user_id"], session["session_nonce"]) do
      %{enabled: true} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}
    end
  end

  # The user a session points at, only while its nonce is still the current one.
  defp session_user(user_id, nonce) do
    case Users.get_user(user_id) do
      %{session_nonce: ^nonce} = user when is_binary(nonce) -> user
      _ -> nil
    end
  end
end
