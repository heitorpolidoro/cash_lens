defmodule CashLensWeb.NavbarComponent do
  use CashLensWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    CashLensWeb.NavbarComponentHTML.navbar(assigns)
  end
end
