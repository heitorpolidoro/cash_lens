defmodule CashLensWeb.UserPendingController do
  use CashLensWeb, :controller

  def show(conn, _params) do
    render(conn, :show)
  end
end
