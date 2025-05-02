defmodule CashLensWeb.MenuComponent do
  use CashLensWeb, :live_component

  def update(assigns, socket) do
    current_path = assigns[:current_path] || "/"
    {:ok, assign(socket, Map.put(assigns, :current_path, current_path))}
  end

  def menu_item_class(current_path, item_path) do
    base_class = "flex items-center px-4 py-2 text-sm font-medium rounded-md"

    if current_path == item_path do
      "#{base_class} text-indigo-700 bg-indigo-50 hover:bg-indigo-100 hover:text-indigo-900"
    else
      "#{base_class} text-gray-700 hover:bg-gray-100 hover:text-gray-900"
    end
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-y-0 left-0 w-64 bg-white border-r border-gray-200">
      <div class="flex flex-col h-full">
        <div class="p-4">
          <h2 class="text-lg font-semibold text-gray-900">Menu</h2>
        </div>
        <nav class="flex-1 px-2 py-4 space-y-1">
          <.link
            href={~p"/"}
            class={menu_item_class(@current_path, "/")}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6" />
            </svg>
            Dashboard
          </.link>
          <.link
            href={~p"/transactions"}
            class={menu_item_class(@current_path, "/transactions")}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Transactions
          </.link>
          <.link
            href={~p"/accounts"}
            class={menu_item_class(@current_path, "/accounts")}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H6a3 3 0 00-3 3v8a3 3 0 003 3z" />
            </svg>
            Accounts
          </.link>
          <.link
            href={~p"/categories"}
            class={menu_item_class(@current_path, "/categories")}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
            </svg>
            Categories
          </.link>
          <.link
            href={~p"/reports"}
            class={menu_item_class(@current_path, "/reports")}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
            </svg>
            Reports
          </.link>
        </nav>
        <div class="p-4 border-t border-gray-200">
          <.link
            href={~p"/logout"}
            method="delete"
            class={if String.starts_with?(@current_path, "/logout"), do: "flex items-center px-4 py-2 text-sm font-medium text-red-700 bg-red-50 rounded-md hover:bg-red-100 hover:text-red-800", else: "flex items-center px-4 py-2 text-sm font-medium text-red-600 rounded-md hover:bg-red-50 hover:text-red-700"}
          >
            <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1" />
            </svg>
            Logout
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
