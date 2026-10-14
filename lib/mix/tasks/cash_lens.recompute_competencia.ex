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
    # Row-level security: maintenance work acts for the operator (CL-53).
    CashLens.Ownership.pin_operator!()
    # TRANSITIONAL: removed when CL-51 converts the caller
    user = CashLens.Ownership.current_user!()
    n = CashLens.CreditCards.recompute_competencia(user)
    Mix.shell().info("Recomputed competência for #{n} statement(s).")
  end
end
