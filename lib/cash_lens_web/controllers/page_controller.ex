defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: {CashLensWeb.Layouts, :app})
  end
end
