defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view
  import CashLensWeb.BaseLive
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  def render(assigns) do
    ~H"""
      <.crud {assigns} target={Transaction} formatter={
        %{
        }
      }/>
    """
  end
end
