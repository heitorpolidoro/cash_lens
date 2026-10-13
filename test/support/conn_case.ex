defmodule CashLensWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CashLensWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CashLensWeb.Endpoint

      use CashLensWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CashLensWeb.ConnCase
    end
  end

  # Every web test runs as an enabled, logged-in user unless it is tagged
  # `@tag :logged_out` (or `@moduletag :logged_out`), which the auth tests use.
  setup tags do
    CashLens.DataCase.setup_sandbox(tags)

    if tags[:logged_out] do
      {:ok, conn: Phoenix.ConnTest.build_conn()}
    else
      context = register_and_log_in_user(%{conn: Phoenix.ConnTest.build_conn()})
      # Fixtures run in the test process, under row-level security: act for the
      # logged-in user, as the request will.
      CashLens.Repo.put_current_user_id(context.user.id)
      context
    end
  end

  @doc "Creates an enabled user and puts it in the session of `conn`."
  def register_and_log_in_user(%{conn: conn}) do
    user = CashLens.UsersFixtures.user_fixture(%{enabled: true})
    %{conn: log_in_user(conn, user), user: user}
  end

  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
    |> Plug.Conn.put_session(:session_nonce, user.session_nonce)
  end
end
