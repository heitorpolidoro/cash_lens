defmodule CashLens.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CashLensWeb.Telemetry,
      {Phoenix.PubSub, name: CashLens.PubSub},
      {Mongo, [name: :mongo, url: System.get_env("MONGODB_URL", "mongodb://mongodb:27017/cash_lens")]},
      {Redix, {System.get_env("REDIS_URL", "redis://redis:6379"), [name: :redix]}},
      CashLensWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CashLens.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CashLensWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
