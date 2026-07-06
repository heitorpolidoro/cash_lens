defmodule CashLensWeb.RedirectController do
  use CashLensWeb, :controller

  def statements(conn, _params) do
    redirect(conn, to: ~p"/statements")
  end
end
