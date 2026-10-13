defmodule CashLensWeb.HealthController do
  use CashLensWeb, :controller

  @doc """
  200 when the database answers, 503 otherwise. The check is injectable via
  `config :cash_lens, :health_check` (a zero-arity function) for tests.
  """
  def show(conn, _params) do
    check = Application.get_env(:cash_lens, :health_check, &CashLens.Health.database_ok?/0)

    if safe_check(check) do
      json(conn, %{status: "ok"})
    else
      conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end

  defp safe_check(check) do
    check.() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
