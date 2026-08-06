defmodule CashLens.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CashLensWeb.Telemetry,
        CashLens.Repo,
        {DNSCluster, query: Application.get_env(:cash_lens, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CashLens.PubSub},
        {Oban, Application.fetch_env!(:cash_lens, Oban)}
      ] ++
        live_preview_cache_children() ++
        [
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

  # The live-preview cache does real network work on boot. Keeping it out of
  # the test supervision tree means tests never race against a real fetch and
  # never have to stub it just to avoid an error status leaking into renders.
  # Tests that need one start their own named instance.
  if Mix.env() == :test do
    defp live_preview_cache_children, do: []
  else
    defp live_preview_cache_children, do: [CashLens.Pluggy.LivePreviewCache]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CashLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
