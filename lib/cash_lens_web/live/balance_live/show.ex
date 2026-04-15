defmodule CashLensWeb.BalanceLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Accounting

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-8">
      <.header>
        Balance {@balance.id}
        <:subtitle>This is a balance record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/balances"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/balances/#{@balance}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit balance
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Year">{@balance.year}</:item>
        <:item title="Month">{@balance.month}</:item>
        <:item title="Initial balance">{@balance.initial_balance}</:item>
        <:item title="Income">{@balance.income}</:item>
        <:item title="Expenses">{@balance.expenses}</:item>
        <:item title="Balance">{@balance.balance}</:item>
        <:item title="Final balance">{@balance.final_balance}</:item>
      </.list>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Balance")
     |> assign(:balance, Accounting.get_balance!(id))}
  end
end
