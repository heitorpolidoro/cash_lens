defmodule CashLens.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    unless Mix.env == :prod do
      # Dotenv.load
      Mix.Task.run("loadconfig")
    end
    children = [
      CashLensWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:cash_lens, :dns_cluster_query) || :ignore},
      # Start the Ecto repository
      CashLens.Repo,
      {Phoenix.PubSub, name: CashLens.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: CashLens.Finch},
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CashLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
