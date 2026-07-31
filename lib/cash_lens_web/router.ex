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

    get "/", PageController, :home
    get "/.well-known/appspecific/com.chrome.devtools.json", PageController, :chrome_devtools
    get "/credit_card_links", RedirectController, :statements

    live_session :default, layout: {CashLensWeb.Layouts, :app} do
      live "/accounts", AccountLive.Index, :index
      live "/accounts/new", AccountLive.Form, :new
      live "/accounts/:id", AccountLive.Show, :show
      live "/accounts/:id/edit", AccountLive.Form, :edit

      live "/transactions", TransactionLive.Index, :index
      live "/transactions/new", TransactionLive.Form, :new
      live "/transactions/:id", TransactionLive.Show, :show
      live "/transactions/:id/edit", TransactionLive.Form, :edit

      live "/categories", CategoryLive.Index, :index
      live "/categories/new", CategoryLive.Form, :new
      live "/categories/:id", CategoryLive.Show, :show
      live "/categories/:id/edit", CategoryLive.Form, :edit

      live "/balances", BalanceLive.Index, :index

      live "/months/:year/:month", MonthLive.Show, :show

      live "/reimbursements", ReimbursementLive.Index, :index
      live "/transfers", TransferLive.Index, :index
      live "/statements", CreditCardStatementLive.Index, :index
      live "/pluggy", PluggyLive.Index, :index
      live "/installments", InstallmentLive.Index, :index
      live "/forecast", ForecastLive.Index, :index

      live "/admin/db", AdminDatabaseLive, :index
      live "/admin/db/:table", AdminDatabaseLive, :show

      live "/admin/exclusion_rules", AutomationLive.BulkIgnore, :index
      live "/admin/transfer_rules", AutomationLive.TransferRules, :index
    end
  end

  scope "/api", CashLensWeb.Api do
    pipe_through :api

    resources "/accounts", AccountController, except: [:new, :edit]
    resources "/categories", CategoryController, except: [:new, :edit]
    resources "/transactions", TransactionController, except: [:new, :edit, :create]
    resources "/balances", BalanceController, only: [:index, :show]

    resources "/installment_groups", InstallmentGroupController,
      only: [:index, :show, :update, :delete]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
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
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
