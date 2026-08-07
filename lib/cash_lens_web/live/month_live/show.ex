defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLensWeb.MonthLive.MonthPanel

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"year" => year_str, "month" => month_str} = params, _uri, socket) do
    with {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      compare = parse_compare_param(params["compare"])
      row_orders = compute_row_orders(year, month, compare)

      {:noreply,
       socket
       |> assign(:primary, build_primary_props(year, month, compare, row_orders))
       |> assign(:compare, compare && build_compare_props(year, month, compare, row_orders))}
    else
      _ ->
        today = Date.utc_today()
        {:noreply, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  @impl true
  def handle_event("open_compare", _params, socket) do
    %{year: year, month: month} = socket.assigns.primary
    {py, pm} = prev_month(year, month)
    {:noreply, push_patch(socket, to: ~p"/months/#{year}/#{month}?#{[compare: "#{py}-#{pm}"]}")}
  end

  @impl true
  def handle_event("close_compare", _params, socket) do
    %{year: year, month: month} = socket.assigns.primary
    {:noreply, push_patch(socket, to: ~p"/months/#{year}/#{month}")}
  end

  # "YYYY-M" (no zero-padding) -> {year, month}, or `nil` for anything malformed —
  # an invalid/garbage compare param degrades to "no comparison" rather than
  # erroring the whole page.
  defp parse_compare_param(nil), do: nil

  defp parse_compare_param(param) do
    with [year_str, month_str] <- String.split(param, "-", parts: 2),
         {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      {year, month}
    else
      _ -> nil
    end
  end

  # `nil` when comparison is off (today's behavior — panels use their own natural
  # order). When on, one merged order per section, given to both panels so their
  # rows land on the same line.
  defp compute_row_orders(_primary_year, _primary_month, nil), do: nil

  defp compute_row_orders(primary_year, primary_month, {compare_year, compare_month}) do
    %{
      "credit" =>
        merged_order(
          Transactions.get_month_income_breakdown(primary_year, primary_month),
          Transactions.get_month_income_breakdown(compare_year, compare_month)
        ),
      "debit" =>
        merged_order(
          Transactions.get_month_category_breakdown(primary_year, primary_month),
          Transactions.get_month_category_breakdown(compare_year, compare_month)
        )
    }
  end

  # Primary's own order first, then any compare-only category (in compare's own
  # order) appended at the end — see the plan's Global Constraints.
  defp merged_order(primary_rows, compare_rows) do
    primary_ids = MapSet.new(primary_rows, & &1.category_id)

    compare_only =
      Enum.reject(compare_rows, &MapSet.member?(primary_ids, &1.category_id))

    (primary_rows ++ compare_only)
    |> Enum.map(&Map.take(&1, [:category_id, :name, :type]))
  end

  defp build_primary_props(year, month, compare, row_orders) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "primary",
      year: year,
      month: month,
      prev_href: primary_href(py, pm, compare),
      next_href: primary_href(ny, nm, compare),
      row_order: row_orders
    }
  end

  defp primary_href(year, month, nil), do: ~p"/months/#{year}/#{month}"

  defp primary_href(year, month, {cy, cm}),
    do: ~p"/months/#{year}/#{month}?#{[compare: "#{cy}-#{cm}"]}"

  defp build_compare_props(primary_year, primary_month, {year, month}, row_orders) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: "compare",
      year: year,
      month: month,
      prev_href: compare_href(primary_year, primary_month, py, pm),
      next_href: compare_href(primary_year, primary_month, ny, nm),
      row_order: row_orders
    }
  end

  defp compare_href(primary_year, primary_month, year, month),
    do: ~p"/months/#{primary_year}/#{primary_month}?#{[compare: "#{year}-#{month}"]}"

  defp prev_month(year, 1), do: {year - 1, 12}
  defp prev_month(year, month), do: {year, month - 1}

  defp next_month(year, 12), do: {year + 1, 1}
  defp next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["py-8", (@compare && "px-4") || "max-w-4xl mx-auto"]}>
      <div class="flex justify-end mb-6">
        <button :if={!@compare} phx-click="open_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-arrows-right-left" class="size-4 mr-1" /> Comparar
        </button>
        <button :if={@compare} phx-click="close_compare" class="btn btn-outline btn-sm">
          <.icon name="hero-x-mark" class="size-4 mr-1" /> Fechar comparação
        </button>
      </div>

      <div class={["grid gap-6", (@compare && "grid-cols-1 lg:grid-cols-2") || "grid-cols-1"]}>
        <.live_component module={MonthPanel} {@primary} />
        <.live_component :if={@compare} module={MonthPanel} {@compare} />
      </div>
    </div>
    """
  end
end
