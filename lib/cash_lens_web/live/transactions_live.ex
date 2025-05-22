defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view
  on_mount CashLensWeb.BaseLive
  use CashLensWeb.BaseLive


  alias CashLens.Transactions

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       transactions: Transactions.list_transactions(desc: :id)
     )}
  end

  def render(assigns) do
    CashLensWeb.TransactionsLiveHTML.transactions(assigns)
  end
end
