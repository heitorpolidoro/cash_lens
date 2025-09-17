# TODO Review
defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Transactions
        <:actions>
          <.link href={~p"/transactions/new"}>
            <.button>New Transaction</.button>
          </.link>
        </:actions>
      </.header>
      <.live_component module={CashLensWeb.TransactionsTableLive} id="transactions_table" />
    </div>
    """
  end
end
