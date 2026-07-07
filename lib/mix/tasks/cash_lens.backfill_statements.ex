defmodule Mix.Tasks.CashLens.BackfillStatements do
  @shortdoc "Re-reads credit-card statement files and stamps import_batch_id"
  @moduledoc """
      mix cash_lens.backfill_statements <caminho>

  Defaults `<caminho>` to the saved `last_batch_import_path` setting. Walks
  the `.account` folder structure exactly like `mix cash_lens.import`, but
  only for credit-card accounts: for each file it re-parses the content,
  creates a `CashLens.CreditCards.Statement` for that file, and stamps the
  matching *already-existing* transactions with the new statement's id as
  `import_batch_id` (by recomputing the same fingerprint the original import
  produced). Categories, amounts and descriptions are never modified, and no
  new transactions are inserted — this only backfills history.
  """
  use Mix.Task

  alias CashLens.CreditCards
  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Parsers.Ingestor

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    path =
      case args do
        [p | _] -> p
        [] -> CashLens.Settings.get("last_batch_import_path", "")
      end

    case DirectoryImporter.each_credit_card_file(path, &backfill_one/3) do
      {:error, reason} ->
        Mix.shell().error(reason)
        exit({:shutdown, 1})

      _ ->
        Mix.shell().info("Backfill complete.")
    end
  end

  defp backfill_one(account, content, file_path) do
    meta = Ingestor.statement_meta(content, file_path)

    case Ingestor.parse(content, account.parser_type) do
      {:error, reason} ->
        Mix.shell().error("#{Path.basename(file_path)}: #{reason}")

      parsed ->
        {:ok, _statement} =
          CreditCards.backfill_file(account, parsed, meta, Path.basename(file_path))

        Mix.shell().info("#{account.name} — #{Path.basename(file_path)}: ok")
    end
  end
end
