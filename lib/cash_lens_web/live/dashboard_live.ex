defmodule CashLensWeb.DashboardLive do
  use CashLensWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Dashboard",
       pie_chart: %{labels: [], data: []},
       line_chart: %{labels: [], datasets: []}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-4">Dashboard</h1>

      <div class="space-y-8">
        <div class="bg-white p-4 rounded-lg shadow">
          <h3 class="font-semibold mb-4">Percentual por Categoria (Todo o período)</h3>
          <div class="mx-auto max-w-xl h-72">
            <canvas id="pie-categories" class="w-full h-full" phx-hook="PieChart" data-chart={Jason.encode!(@pie_chart)}></canvas>
          </div>
        </div>

        <div class="bg-white p-4 rounded-lg shadow">
          <h3 class="font-semibold mb-4">Soma por Categoria por Mês</h3>
          <div class="mx-auto max-w-5xl h-96">
            <canvas id="line-categories-month" class="w-full h-full" phx-hook="LineChart" data-chart={Jason.encode!(@line_chart)}></canvas>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {pie, line} = load_charts()
    {:noreply, assign(socket, pie_chart: pie, line_chart: line)}
  end

  defp load_charts do
    txs = CashLens.Transactions.list_transactions()
      |> Stream.filter(& &1.category)
    |> Stream.reject(fn t -> t.category == "Transfer" end)
    |> Enum.map(fn t ->
    %{t | amount: Decimal.negate(t.amount)}
    end)

    pie = build_pie_chart(txs)
    line = build_line_chart(txs)
    {pie, line}
  end

  defp build_pie_chart(transactions) do
    totals_by_cat =
      transactions
      |> Enum.group_by(&(&1.category || "Sem Categoria"))
      |> Enum.map(fn {cat, list} ->
        sum =
          list
          |> Enum.map(&(&1.amount || Decimal.new(0)))
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        {cat, sum}
      end)
      |> Enum.sort_by(fn {cat, _} -> cat end)

    totals = Enum.map(totals_by_cat, fn {_cat, dec} -> decimal_to_float(dec) end)
    total_sum = Enum.sum(totals)
    data =
      if total_sum > 0 do
        Enum.map(totals, fn v -> Float.round(v * 100.0 / total_sum, 2) end)
      else
        Enum.map(totals, fn _ -> 0.0 end)
      end

    labels = Enum.zip(totals_by_cat, data)
      |> Enum.map(fn {{label, _}, percentage} ->
        "#{label} (#{percentage}%)"
    end)

    %{labels: labels, data: data, totals: totals}
  end

  defp build_line_chart(transactions) do
    months =
      transactions
      |> Enum.map(fn t -> ym_label(t.date) end)
      |> Enum.uniq()
      |> Enum.sort()

    categories =
      transactions
      |> Enum.map(fn t -> t.category || "Sem Categoria" end)
      |> Enum.uniq()
      |> Enum.sort()

    sums =
      transactions
      |> Enum.reduce(%{}, fn t, acc ->
        cat = t.category || "Sem Categoria"
        ym = ym_label(t.date)
        key = {cat, ym}
        amount = t.amount || Decimal.new(0)
        Map.update(acc, key, amount, &Decimal.add(&1, amount))
      end)

    datasets =
      for cat <- categories do
        data =
          for ym <- months do
            dec = Map.get(sums, {cat, ym}, Decimal.new(0))
            decimal_to_float(dec)
          end

        %{label: cat, data: data}
      end

    %{labels: months, datasets: datasets}
  end

  defp ym_label(%Date{} = d),
    do: "#{d.year}-" <> String.pad_leading(Integer.to_string(d.month), 2, "0")

  defp ym_label(%DateTime{} = dt), do: dt |> DateTime.to_date() |> ym_label()
  defp ym_label(%NaiveDateTime{} = ndt), do: ndt |> NaiveDateTime.to_date() |> ym_label()

  defp decimal_to_float(%Decimal{} = d), do: d |> Decimal.to_float()
  defp decimal_to_float(other) when is_number(other), do: other * 1.0
end
