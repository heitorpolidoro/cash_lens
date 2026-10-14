defmodule Mix.Tasks.CashLens.ReconcilePendingStatements do
  use Mix.Task
  @shortdoc "Absorbs existing pending statements into their boletos"

  @moduledoc """
      mix cash_lens.reconcile_pending_statements [--user <email>]

  One-time reconciliation over already-imported data: absorbs each non-boleto
  (no Vencimento) statement into the next boleto whose accounts reconcile
  exactly, propagating an already-linked payment. Idempotent.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {email, _rest} = CashLens.Operator.parse_args(args)
    user = CashLens.Operator.user!(email)
    n = CashLens.CreditCards.reconcile_pending(user)
    Mix.shell().info("Reconciled: #{n} statement(s) absorbed.")
  end
end
