defmodule CashLensWeb.MonthLive.Show do
  use CashLensWeb, :live_view

  alias CashLensWeb.MonthLive.MonthPanel

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"year" => year_str, "month" => month_str}, _uri, socket) do
    with {year, ""} <- Integer.parse(year_str),
         {month, ""} <- Integer.parse(month_str),
         true <- month in 1..12,
         {:ok, _date} <- Date.new(year, month, 1) do
      {:noreply, assign(socket, :primary, build_panel_props("primary", year, month))}
    else
      _ ->
        today = Date.utc_today()
        {:noreply, push_navigate(socket, to: ~p"/months/#{today.year}/#{today.month}")}
    end
  end

  defp build_panel_props(id, year, month) do
    {py, pm} = prev_month(year, month)
    {ny, nm} = next_month(year, month)

    %{
      id: id,
      year: year,
      month: month,
      prev_href: ~p"/months/#{py}/#{pm}",
      next_href: ~p"/months/#{ny}/#{nm}"
    }
  end

  def prev_month(year, 1), do: {year - 1, 12}
  def prev_month(year, month), do: {year, month - 1}

  def next_month(year, 12), do: {year + 1, 1}
  def next_month(year, month), do: {year, month + 1}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-8 max-w-4xl mx-auto">
      <.live_component module={MonthPanel} {@primary} />
    </div>
    """
  end
end
