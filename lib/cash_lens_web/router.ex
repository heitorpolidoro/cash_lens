defmodule CashLensWeb.Router do
  use CashLensWeb, :router

  import CashLensWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CashLensWeb.Layouts, :root}
    plug :protect_from_forgery
    plug CashLensWeb.Plugs.SecurityHeaders
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    # The API authenticates with the session cookie, so unsafe verbs need the
    # CSRF token too (sent in the `x-csrf-token` header).
    plug :protect_from_forgery
    plug :require_enabled_user_api
  end

  # Credential endpoints: attempts are counted per client IP (and, for log in,
  # per email) and answered with 429 over the limit. Runs before the handlers
  # so a throttled request never reaches bcrypt.
  pipeline :rate_limit_register do
    plug CashLensWeb.Plugs.RateLimit, bucket: :register
  end

  pipeline :rate_limit_login do
    plug CashLensWeb.Plugs.RateLimit, bucket: :login
  end

  scope "/", CashLensWeb do
    pipe_through [:browser, :redirect_if_authenticated, :rate_limit_register]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create

    # Request forms that send an email share the sign-up limit.
    get "/users/reset_password", UserResetPasswordController, :new
    post "/users/reset_password", UserResetPasswordController, :create
    get "/users/confirm", UserConfirmationController, :new
    post "/users/confirm", UserConfirmationController, :create
  end

  scope "/", CashLensWeb do
    pipe_through [:browser, :redirect_if_authenticated, :rate_limit_login]

    get "/users/log_in", UserSessionController, :new
    post "/users/log_in", UserSessionController, :create
  end

  scope "/", CashLensWeb do
    pipe_through :browser

    get "/.well-known/appspecific/com.chrome.devtools.json", PageController, :chrome_devtools
    delete "/users/log_out", UserSessionController, :delete

    get "/users/confirm/:token", UserConfirmationController, :confirm
    get "/users/reset_password/:token", UserResetPasswordController, :edit
    put "/users/reset_password/:token", UserResetPasswordController, :update

    get "/privacy", PrivacyController, :show
  end

  # Outside every pipeline: no session, no CSRF, no login.
  scope "/", CashLensWeb do
    get "/health", HealthController, :show
  end

  scope "/", CashLensWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/pending", UserPendingController, :show
  end

  scope "/", CashLensWeb do
    pipe_through [:browser, :require_authenticated_user, :require_enabled_user]

    get "/", PageController, :home

    get "/account", UserAccountController, :show
    get "/account/export", UserAccountController, :export
    delete "/account", UserAccountController, :delete
    get "/credit_card_links", RedirectController, :statements

    # The two rule screens merged into the Automation Center (CL-17); the old
    # paths stay reachable and land on the tab they used to be.
    get "/admin/exclusion_rules", RedirectController, :exclusion_rules
    get "/admin/transfer_rules", RedirectController, :transfer_rules

    live_session :default,
      layout: {CashLensWeb.Layouts, :app},
      on_mount: [
        {CashLensWeb.UserAuth, :require_enabled_user},
        CashLensWeb.ActivePath,
        CashLensWeb.RecurringSyncFlash
      ] do
      # The create and edit routes are an overlaid modal on top of the accounts
      # screen, not standalone pages: they mount `Index` so a `live_patch`
      # opens/closes the account settings form without leaving the cards
      # behind it (CL-15).
      live "/accounts", AccountLive.Index, :index
      live "/accounts/new", AccountLive.Index, :new
      live "/accounts/:id", AccountLive.Show, :show
      live "/accounts/:id/edit", AccountLive.Index, :edit

      # The form, detail and edit routes are overlaid modals on top of the
      # statement, not standalone pages: they all mount `Index` so a
      # `live_patch` opens/closes them without re-fetching the infinite-scroll
      # stream or losing the user's scroll position (CL-10).
      live "/transactions", TransactionLive.Index, :index
      live "/transactions/new", TransactionLive.Index, :new
      live "/transactions/:id", TransactionLive.Index, :show
      live "/transactions/:id/edit", TransactionLive.Index, :edit

      live "/categories", CategoryLive.Index, :index
      live "/categories/new", CategoryLive.Index, :new
      live "/categories/:id", CategoryLive.Show, :show
      live "/categories/:id/edit", CategoryLive.Index, :edit

      live "/balances", BalanceLive.Index, :index

      live "/months/:year/:month", MonthLive.Show, :show

      live "/reimbursements", ReimbursementLive.Index, :index
      live "/transfers", TransferLive.Index, :index
      live "/statements", CreditCardStatementLive.Index, :index
      live "/imports", ImportLive.Index, :index
      live "/installments", InstallmentLive.Index, :index
      live "/forecast", ForecastLive.Index, :index

      # The registered monthly accounts are read by the forecast, the dashboard
      # and the projection, so they get a screen of their own. The form opens as
      # an overlaid modal, like the other cadastros.
      live "/recurring_items", RecurringItemLive.Index, :index
      live "/recurring_items/new", RecurringItemLive.Index, :new
      live "/recurring_items/:id/edit", RecurringItemLive.Index, :edit

      live "/admin/db", AdminDatabaseLive, :index
      live "/admin/db/:table", AdminDatabaseLive, :show

      live "/automation", AutomationLive.Index, :index
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

      live_dashboard "/dashboard",
        metrics: CashLensWeb.Telemetry,
        csp_nonce_assign_key: :csp_nonce

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
