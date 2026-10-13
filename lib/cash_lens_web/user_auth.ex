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

  alias CashLens.Repo
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

    conn
    |> assign(:current_user, user)
    |> bind_database_user(user)
  end

  # Row-level security: the database sees this request as acting for `user` (and
  # for nobody when `user` is nil). The request process is reused by keep-alive
  # connections, so the previous binding (normally none) is put back before the
  # response goes out.
  defp bind_database_user(conn, user) do
    previous = Repo.current_user_id()
    Repo.put_current_user_id(user && user.id)
    register_before_send(conn, fn conn -> restore_database_user(conn, previous) end)
  end

  defp restore_database_user(conn, previous) do
    Repo.put_current_user_id(previous)
    conn
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
        conn |> assign(:current_user, user) |> bind_database_user(user)

      _ ->
        conn
        |> bind_database_user(nil)
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "Unauthorized"}})
        |> halt()
    end
  end

  @doc "LiveView hook: re-checks the user on every mount, including reconnects."
  def on_mount(:require_enabled_user, _params, session, socket) do
    case session_user(session["user_id"], session["session_nonce"]) do
      %{enabled: true} = user ->
        # The LiveView process acts for this user for its whole life.
        Repo.put_current_user_id(user.id)
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
