defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  def well_known(conn, _params) do
    send_resp(conn, 204, "")
  end
end
