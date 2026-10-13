defmodule CashLens.Health do
  @moduledoc "Liveness check used by `GET /health`: is the database reachable?"

  @timeout 2_000

  @doc "True when a trivial query succeeds within the timeout; never raises."
  def database_ok? do
    match?({:ok, _}, CashLens.Repo.query("SELECT 1", [], timeout: @timeout))
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
