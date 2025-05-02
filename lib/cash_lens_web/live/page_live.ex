defmodule CashLensWeb.PageLive do
  use CashLensWeb, :live_view

  def mount(_params, session, socket) do
    {:ok, assign(socket, current_user: session["current_user"], current_path: "/")}
  end

  def render(assigns) do
    CashLensWeb.PageLiveHTML.page(assigns)
  end
end
