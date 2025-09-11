defmodule CashLensWeb.HomeLive do
  use CashLensWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <.header>
      Home
    </.header>
    """
  end
end
