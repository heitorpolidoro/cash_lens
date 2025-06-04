defmodule CashLensWeb.MenuComponentHTML do
  use Phoenix.Component
  use CashLensWeb, :live_component
  import CashLensWeb.CoreComponents
  import SaladUI.Sidebar

  embed_templates "menu_component/*"

  def menu_item_class(current_path, item_path) do
    base_class = "flex items-center px-4 py-2 text-sm font-medium rounded-md"

    if current_path == item_path do
      "#{base_class} text-indigo-700 bg-indigo-50 hover:bg-indigo-100 hover:text-indigo-900"
    else
      "#{base_class} text-gray-700 hover:bg-gray-100 hover:text-gray-900"
    end
  end

end
