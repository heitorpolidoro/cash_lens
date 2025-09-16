defmodule CashLensWeb.HomeLive do
  use CashLensWeb, :live_view

  alias CashLens.Balances
  alias LiveCharts

  @chart_colors [
    # Green
    "#52965C",
    # Red
    "#D9534F",
    # Orange
    "#F0AD4E",
    # Blue
    "#3468B3"
  ]

  @impl true
  def mount(_params, _session, socket) do
    chart = build_balance_chart()
    {:ok, assign(socket, balance_chart: chart)}
  end

  defp build_balance_chart do
    summaries = Balances.monthly_summary()

    labels =
      summaries
      |> Enum.map(fn %{month: month} -> Calendar.strftime(month, "%Y-%m") end)

    to_float = fn
      nil -> 0.0
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_number(n) -> n / 1
    end

    series_in = summaries |> Enum.map(&to_float.(&1.total_in))

    series_out =
      summaries
      |> Enum.map(fn s ->
        v = to_float.(s.total_out)
        abs(v)
      end)

    series_balance = summaries |> Enum.map(&to_float.(&1.balance))
    series_final = summaries |> Enum.map(&to_float.(&1.final_value))

    LiveCharts.build(%{
      id: "balance-chart",
      type: :bar,
      adapter: LiveCharts.Adapter.ApexCharts,
      options: %{
        xaxis: %{categories: labels},
        legend: %{position: "bottom"},
        dataLabels: %{
          enabled: true,
          style: %{
            colors: @chart_colors
          },
          offsetY: -20
        },
        plotOptions: %{
          bar: %{dataLabels: %{position: "top"}}
        },
        stroke: %{width: [0, 0, 0, 2]},
        markers: %{size: [0, 0, 0, 3]},
        tooltip: %{enabled: true},
        #      yaxis: [%{labels: %{formatter: fn val -> val end}}],
        chart: %{height: 360},
        colors: @chart_colors
      },
      series: [
        %{name: "Total In", data: series_in},
        %{name: "Total Out", data: series_out},
        %{name: "Balance", data: series_balance},
        # Using a line for Final Value via ApexCharts combo support
        %{name: "Total", data: series_final, type: "line"}
      ]
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Home
    </.header>

    <div class="px-4 py-6">
      <h2 class="text-lg font-semibold mb-4">Balance</h2>
      <div class="bg-white rounded-lg shadow p-4" style="height: 360px;">
        <LiveCharts.chart chart={@balance_chart} />
      </div>
    </div>
    """
  end
end
