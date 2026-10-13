defmodule Mix.Tasks.CashLens.MigrateOurocardTxt do
  use Mix.Task
  import Ecto.Query

  alias CashLens.Accounts.Account
  alias CashLens.CreditCards
  alias CashLens.Repo

  @shortdoc "Wipes ourocard_ofx accounts and switches them to the TXT parser"

  @moduledoc """
      mix cash_lens.migrate_ourocard_txt

  One-time migration: for every account with parser_type "ourocard_ofx",
  deletes its statements and transactions and sets parser_type to
  "ourocard_txt". After running this, delete the account's .ofx files, drop
  the re-exported .txt files in its folder, then re-import + backfill.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    # Row-level security: maintenance work acts for the operator (CL-53).
    CashLens.Ownership.pin_operator!()

    accounts =
      from(a in Account, where: a.parser_type == "ourocard_ofx")
      |> Repo.all()

    Enum.each(accounts, fn account ->
      {stmts, txns} = CreditCards.reset_account_statements(account.id)

      {:ok, _} =
        account
        |> Account.changeset(%{parser_type: "ourocard_txt"})
        |> Repo.update()

      Mix.shell().info(
        "#{account.name}: deleted #{stmts} statements, #{txns} transactions; parser -> ourocard_txt"
      )
    end)

    Mix.shell().info("Done. Now: delete .ofx files, add .txt files, then import + backfill.")
  end
end
