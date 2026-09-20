defmodule CashLensWeb.RedirectController do
  use CashLensWeb, :controller

  def statements(conn, _params) do
    redirect(conn, to: ~p"/statements")
  end

  def exclusion_rules(conn, _params) do
    redirect(conn, to: ~p"/automation?tab=exclusions")
  end

  def transfer_rules(conn, _params) do
    redirect(conn, to: ~p"/automation?tab=transfers")
  end
end
