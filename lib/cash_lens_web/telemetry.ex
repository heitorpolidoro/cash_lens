defmodule CashLensWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Add reporters as children of your supervision tree.
      {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Accounting Metrics
      summary("cash_lens.accounting.calculate_balance.stop.duration",
        unit: {:native, :millisecond},
        description: "The time it takes to calculate a monthly balance",
        tags: [:status]
      ),
      counter("cash_lens.accounting.calculate_balance.stop.duration",
        description: "Number of balance calculations performed",
        tags: [:status]
      ),

      # Phoenix Metrics
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        at: [:duration],
        tags: [:route]
      ),
      summary("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        at: [:duration],
        tags: [:route]
      ),

      # Database Metrics
      summary("cash_lens.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("cash_lens.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("cash_lens.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("cash_lens.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("cash_lens.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3.
      # {CashLensWeb, :count_users, []}
    ]
  end
end
