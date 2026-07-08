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
    n = CashLens.CreditCards.reconcile_pending()
    Mix.shell().info("Reconciled: #{n} statement(s) absorbed.")
  end
end
