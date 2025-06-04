defmodule CashLensWeb.MenuComponent do
  use CashLensWeb, :live_component

  def update(assigns, socket) do
    current_path = assigns[:current_path] || "/"
    {:ok, assign(socket, Map.put(assigns, :current_path, current_path))}
  end

  def render(assigns) do
    CashLensWeb.MenuComponentHTML.menu(assigns)
  end
end
