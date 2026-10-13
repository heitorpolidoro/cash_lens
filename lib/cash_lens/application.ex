defmodule CashLens.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Reports logged errors to Sentry; a no-op while no DSN is configured.
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:request_id]}
    })

    children =
      migration_repo() ++
        [
          CashLensWeb.Telemetry,
          CashLens.Repo,
          CashLensWeb.Plugs.RateLimit.Store,
          {DNSCluster, query: Application.get_env(:cash_lens, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: CashLens.PubSub},
          {Oban, Application.fetch_env!(:cash_lens, Oban)},
          # Start a worker by calling: CashLens.Worker.start_link(arg)
          # {CashLens.Worker, arg},
          # Start to serve requests, typically the last entry
          CashLensWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CashLens.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The owner repo is only needed at runtime by the schema tests.
  defp migration_repo do
    if Application.get_env(:cash_lens, :start_migration_repo, false),
      do: [CashLens.MigrationRepo],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CashLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
