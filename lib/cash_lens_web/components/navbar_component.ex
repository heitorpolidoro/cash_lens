defmodule CashLensWeb.NavbarComponent do
  use CashLensWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <header class="px-4 sm:px-6 lg:px-8">
      <div class="flex h-16 items-center justify-between">
        <div class="flex items-center">
          <img class="h-8 w-auto" src="/images/cash_lens_logo.jpeg" alt="CashLens" />
          <span class="ml-2 text-xl font-semibold">CashLens</span>
        </div>
        <%= if @current_user do %>
          <div class="flex items-center gap-4">
            <div class="flex items-center gap-2">
              <%= if @current_user.picture do %>
                <img class="h-8 w-8 rounded-full" src={@current_user.picture} alt={@current_user.name} />
              <% end %>
              <span class="text-sm font-medium text-gray-700"><%= @current_user.name %></span>
            </div>
          </div>
        <% end %>
      </div>
    </header>
    """
  end
end
