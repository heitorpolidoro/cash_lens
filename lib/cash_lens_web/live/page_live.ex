defmodule CashLensWeb.PageLive do
  use CashLensWeb, :live_view

  def mount(_params, session, socket) do
    {:ok, assign(socket, current_user: session["current_user"], current_path: "/")}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Add your main content here -->
        Main Content
    </div>
    """
  end
end
