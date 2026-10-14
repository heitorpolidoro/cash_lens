defmodule CashLensWeb.Plugs.DevLoginAs do
  @moduledoc """
  Local development only: signs a visitor in as the user whose email is in
  `CASH_LENS_DEV_LOGIN_AS`, so the login page can be skipped.

  It does nothing unless `config :cash_lens, dev_login_as: true` was set at
  compile time, which only `config/dev.exs` does — a test or production build
  compiles it as a no-op, whatever the environment holds. The user must exist
  and be enabled; a session that already has a user is left alone.
  """
  import Plug.Conn

  alias CashLens.Users

  @behaviour Plug
  @enabled Application.compile_env(:cash_lens, :dev_login_as, false)
  @env "CASH_LENS_DEV_LOGIN_AS"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if @enabled, do: log_in_as(conn, System.get_env(@env)), else: conn
  end

  @doc "Puts the user with `email` in the session, when there is none yet."
  def log_in_as(conn, email) when is_binary(email) and email != "" do
    with nil <- get_session(conn, :user_id),
         %{enabled: true} = user <- Users.get_user_by_email(email) do
      conn
      |> put_session(:user_id, user.id)
      |> put_session(:session_nonce, user.session_nonce)
    else
      _ -> conn
    end
  end

  def log_in_as(conn, _email), do: conn
end
