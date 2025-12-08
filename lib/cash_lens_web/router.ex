defmodule CashLensWeb.Router do
  use CashLensWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CashLensWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CashLensWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/dashboard", DashboardLive, :dashboard
    live "/transactions", TransactionsLive, :transactions
    live "/accounts", AccountsLive, :accounts

    get "/.well-known/*path", PageController, :well_known
  end

  if Application.compile_env(:cash_lens, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CashLensWeb.Telemetry
    end
  end
end
