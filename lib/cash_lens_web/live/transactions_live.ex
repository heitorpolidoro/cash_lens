defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view
#  use CashLensWeb.BaseLive
#  on_mount CashLensWeb.BaseLive


  alias CashLens.Transactions

  def mount(_params, %{"current_user" => current_user} = _session, socket) do
    {:ok,
     socket
     |> assign(
       transactions: Transactions.list_transactions(current_user.id, desc: :id)
     )}
  end

  def render(assigns) do
    "CashLensWeb.TransactionsLiveHTML.transactions(assigns)"
  end
end
