defmodule CashLensWeb.HomeLive do
  use CashLensWeb, :live_view

  alias CashLens.Balances
  alias CashLens.Categories
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
    # Subscribe to balance updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CashLens.PubSub, "balance_updates")
    end

    balance_chart = build_balance_chart() |> IO.inspect()
    category_chart = build_category_chart()
    {:ok, assign(socket, balance_chart: balance_chart, category_chart: category_chart)}
  end

  # Handle the broadcast message and rebuild the chart
  @impl true
  def handle_info({:balance_updated, _changes}, socket) do
    # TODO try to update the values instead of rebuilding the chart
    # This is a naive approach, it rebuilds the entire chart
    balance_chart = build_balance_chart()
    category_chart = build_category_chart()
    {:noreply, assign(socket, balance_chart: balance_chart, category_chart: category_chart)}
  end

  defp to_float(value) do
    case value do
      nil -> 0.0
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_number(n) -> n / 1
    end
  end

  defp append(map, key, value) do
    Map.update(map, key, [value], fn x -> x ++ [value] end)
  end

  defp build_balance_chart do
    chart_data =
      Balances.monthly_summary()
      |> Enum.reduce(%{}, fn summary, acc ->
        acc
        |> append(:labels, Calendar.strftime(summary.month, "%m/%Y"))
        |> append(:total_in, to_float(summary.total_in))
        |> append(:total_out, -to_float(summary.total_out))
        |> append(:balance, to_float(summary.balance))
        |> append(:final_value, to_float(summary.final_value))
      end)

    if chart_data != %{} do
      LiveCharts.build(%{
        id: "balance-chart",
        type: :bar,
        adapter: LiveCharts.Adapter.ApexCharts,
        options: %{
          title: %{text: "Balances"},
          tooltip: %{enabled: true},
          chart: %{height: 340, animations: %{enabled: false}},
          xaxis: %{categories: chart_data.labels},
          plotOptions: %{
            bar: %{dataLabels: %{position: "top"}}
          },
          legend: %{position: "bottom"},
          dataLabels: %{
            enabled: true,
            style: %{
              colors: @chart_colors
            },
            offsetY: -20
          },
          stroke: %{width: [0, 0, 0, 2]},
          markers: %{size: [0, 0, 0, 3]},
          colors: @chart_colors
        },
        series: [
          %{name: "Total In", data: chart_data.total_in},
          %{name: "Total Out", data: chart_data.total_out},
          %{name: "Balance", data: chart_data.balance},
          # Using a line for Final Value via ApexCharts combo support
          %{name: "Total", data: chart_data.final_value, type: "line"}
        ]
      })
    end
  end

  defp build_category_chart() do
    {categories, data} =
      Categories.monthly_summary()
      |> Map.pop(:categories, [])

    # TODO sort by total spend in the range
    labels =
      data
      |> Enum.reduce([], fn {month, _summary}, acc ->
        acc ++ [Calendar.strftime(month, "%m/%Y")]
      end)

    series =
      categories
      |> Enum.map(fn category ->
        category_data =
          Enum.reduce(data, [], fn {month, summary}, acc ->
            acc ++ [to_float(Map.get(summary, category, 0.0))]
          end)

        %{name: category, data: category_data}
      end)

    LiveCharts.build(%{
      id: "category-chart",
      type: :line,
      adapter: LiveCharts.Adapter.ApexCharts,
      options: %{
        title: %{text: "Spending by Category"},
        tooltip: %{enabled: true},
        chart: %{height: 340, animations: %{enabled: false}},
        xaxis: %{categories: labels},
        legend: %{position: "right"},
        stroke: %{width: 2},
        markers: %{size: 3},
        colors: @chart_colors
      },
      series: series
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Home
    </.header>

    <%= if @balance_chart do %>
      <div class="px-4 py-6">
        <div class="bg-white rounded-lg shadow p-4" style="height: 360px;">
          <LiveCharts.chart chart={@balance_chart} />
        </div>
      </div>
    <% end %>

    <%= if @category_chart do %>
      <div class="px-4 py-6">
        <div class="bg-white rounded-lg shadow p-4" style="height: 360px;">
          <LiveCharts.chart chart={@category_chart} />
        </div>
      </div>
    <% end %>
    """
  end
end
