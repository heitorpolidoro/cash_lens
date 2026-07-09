defmodule Mix.Tasks.CashLens.RecomputeCompetencia do
  use Mix.Task
  @shortdoc "Recomputes statement competência from each card's billing cycle"

  @moduledoc """
      mix cash_lens.recompute_competencia

  Recomputes competência for statements on credit-card accounts that have a
  configured cycle. Idempotent. Run after setting/confirming cycles; then
  re-run `mix cash_lens.reconcile_pending_statements`.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    n = CashLens.CreditCards.recompute_competencia()
    Mix.shell().info("Recomputed competência for #{n} statement(s).")
  end
end
