defmodule CashLensWeb.Router do
  use CashLensWeb, :router

  import CashLensWeb.AuthController

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

  pipeline :require_authenticated_user do
    plug :fetch_current_user
  end

  scope "/", CashLensWeb do
    pipe_through [:browser]

    get "/login", AuthController, :login
    get "/unauthorized", AuthController, :unauthorized
  end

  scope "/", CashLensWeb do
    pipe_through [:browser, :require_authenticated_user]

    live "/", PageLive, :index
    live "/transactions", TransactionsLive, :index
    live "/accounts", AccountsLive, :index
    live "/categories", CategoriesLive, :index
    live "/parser_statements", ParsersLive, :index
    delete "/logout", AuthController, :delete
  end

  scope "/auth", CashLensWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback

  end

  # Other scopes may use custom stacks.
  # scope "/api", CashLensWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:cash_lens, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CashLensWeb.Telemetry
    end
  end
end
