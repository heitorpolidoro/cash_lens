defmodule Mix.Tasks.CashLens.ReconcilePendingStatements do
  use Mix.Task
  @shortdoc "Absorbs existing pending statements into their boletos"

  @moduledoc """
      mix cash_lens.reconcile_pending_statements

  One-time reconciliation over already-imported data: absorbs each non-boleto
  (no Vencimento) statement into the next boleto whose accounts reconcile
  exactly, propagating an already-linked payment. Idempotent.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    # Row-level security: maintenance work acts for the operator (CL-53).
    CashLens.Ownership.pin_operator!()
    # TRANSITIONAL: removed when CL-51 converts the caller
    user = CashLens.Ownership.current_user!()
    n = CashLens.CreditCards.reconcile_pending(user)
    Mix.shell().info("Reconciled: #{n} statement(s) absorbed.")
  end
end
