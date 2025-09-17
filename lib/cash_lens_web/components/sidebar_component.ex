# TODO Review
defmodule CashLensWeb.SidebarComponent do
  use CashLensWeb, :html

  alias CashLens.Transfers

  def sidebar(assigns) do
    assigns = assign(assigns, pending_transfers_count: Transfers.get_pending_transfers_count())

    ~H"""
    <aside
      id="sidebar"
      class="fixed inset-y-0 left-0 transform -translate-x-full lg:translate-x-0 z-10 w-64 bg-zinc-50 border-r border-zinc-100 transition duration-200 ease-in-out lg:static lg:h-auto overflow-y-auto pt-16 lg:pt-0"
    >
      <nav class="p-4">
        <div class="space-y-1">
          <a
            href="/"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-home-mini" class="h-5 w-5 mr-3" /> Home
          </a>
          <a
            href="/accounts"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-wallet-mini" class="h-5 w-5 mr-3" /> Accounts
          </a>
          <a
            href="/transactions"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-currency-dollar-mini" class="h-5 w-5 mr-3" /> Transactions
          </a>
          <a
            href="/transfers"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-arrows-right-left-mini" class="h-5 w-5 mr-3" /> Transfers
            <%= if @pending_transfers_count > 0 do %>
              <span class="ml-2 inline-flex items-center justify-center
                px-2 py-0.5 text-xs font-bold leading-none
                text-white bg-red-600 rounded-full">
                {@pending_transfers_count}
              </span>
            <% end %>
          </a>

          <a
            href="/categories"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-tag-mini" class="h-5 w-5 mr-3" /> Categories
          </a>
          <a
            href="/reasons"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-document-text" class="h-5 w-5 mr-3" /> Reasons
          </a>
          <a
            href="/parse-statement"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-document-text-mini" class="h-5 w-5 mr-3" /> Parse Statement
          </a>
          <a
            href="/balances"
            class="flex items-center px-4 py-2 text-sm font-medium text-zinc-900 rounded-md hover:bg-zinc-100"
          >
            <.icon name="hero-banknotes-mini" class="h-5 w-5 mr-3" /> Balances
          </a>
        </div>
      </nav>
    </aside>
    """
  end

  # You can also move the mobile menu button and related JavaScript here
  def mobile_menu_button(assigns) do
    ~H"""
    <div class="lg:hidden fixed top-16 left-4 z-20">
      <button
        type="button"
        id="mobile-menu-button"
        class="text-zinc-500 hover:text-zinc-900 focus:outline-none"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-6 w-6"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M4 6h16M4 12h16M4 18h16"
          />
        </svg>
      </button>
    </div>
    """
  end

  # JavaScript for sidebar toggle functionality
  def sidebar_js(assigns) do
    ~H"""
    <script>
      document.addEventListener('DOMContentLoaded', function() {
        const mobileMenuButton = document.getElementById('mobile-menu-button');
        const sidebar = document.getElementById('sidebar');

        if (mobileMenuButton && sidebar) {
          mobileMenuButton.addEventListener('click', function() {
            const isOpen = sidebar.classList.contains('translate-x-0');

            if (isOpen) {
              sidebar.classList.remove('translate-x-0');
              sidebar.classList.add('-translate-x-full');
            } else {
              sidebar.classList.remove('-translate-x-full');
              sidebar.classList.add('translate-x-0');
            }
          });
        }
      });
    </script>
    """
  end
end
