defmodule CashLensWeb.TelemetryTest do
  use ExUnit.Case, async: false

  alias CashLensWeb.Telemetry, as: AppTelemetry

  test "metrics/0 returns a non-empty list of telemetry metrics" do
    assert [_ | _] = AppTelemetry.metrics()
  end

  test "reporters/0 returns ConsoleReporter when start_console_reporter is true" do
    Application.put_env(:cash_lens, :start_console_reporter, true)

    reporters = AppTelemetry.reporters()
    assert [{Telemetry.Metrics.ConsoleReporter, _opts}] = reporters
  after
    Application.put_env(:cash_lens, :start_console_reporter, false)
  end

  test "reporters/0 returns empty list when start_console_reporter is false" do
    assert AppTelemetry.reporters() == []
  end
end
