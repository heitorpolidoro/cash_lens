defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  require Logger
  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Parsers.CSVParser
  alias CashLens.Parsers.OFXParser
  alias CashLens.Parsers.PDFParser
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias Ecto.UUID

  @doc """
  Parses the content based on the provided parser_type.
  """
  def parse(content, parser_type) do
    case parser_type do
      "bb_csv" ->
        Logger.info("Using BB CSV Parser")
        CSVParser.parse(content, :bb)

      "sem_parar_pdf" ->
        Logger.info("Using Sem Parar PDF Parser")
        PDFParser.parse(content, :sem_parar)

      "standard_ofx" ->
        Logger.info("Using Standard OFX Parser")
        OFXParser.parse(content, :standard)

      _ ->
        {:error, "Extrator não configurado ou não suportado para esta conta."}
    end
  end

  @doc """
  Reads a file, converts encoding/extracts text, parses and saves the transactions.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def import_file(account, file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        process_imported_content(content, account, file_path)

      {:error, reason} ->
        {:error, "Could not read file: #{reason}"}
    end
  end

  @doc """
  Imports all supported files from a directory.
  """
  def import_directory(account, dir_path) do
    if File.dir?(dir_path) do
      results =
        dir_path
        |> File.ls!()
        |> Enum.filter(&supported_file?(&1))
        |> Enum.map(fn filename ->
          path = Path.join(dir_path, filename)
          import_file(account, path)
        end)

      summarize_results(results)
    else
      {:error, "Path is not a directory"}
    end
  end

  defp supported_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in [".csv", ".ofx", ".pdf"]
  end

  defp summarize_results(results) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    total_count = successes |> Enum.map(fn {:ok, count} -> count end) |> Enum.sum()

    if Enum.empty?(errors) do
      {:ok, total_count}
    else
      {:error,
       "#{length(errors)} files failed to import. Total transactions from successful files: #{total_count}"}
    end
  end

  defp process_imported_content(content, account, file_path) do
    content = prepare_content(content, account, file_path)

    case parse(content, account.parser_type) do
      {:error, reason} ->
        {:error, reason}

      transactions_data ->
        finalize_import(transactions_data, account.id)
    end
  end

  defp prepare_content(content, account, file_path) do
    if String.ends_with?(file_path, ".pdf") or account.parser_type == "sem_parar_pdf" do
      converter = Application.get_env(:cash_lens, :pdf_converter)

      case converter.convert(file_path) do
        {:ok, text} -> text
        _ -> content
      end
    else
      ensure_utf8(content)
    end
  end

  defp ensure_utf8(content) do
    if String.valid?(content),
      do: content,
      else: :unicode.characters_to_binary(content, :latin1, :utf8)
  end

  defp finalize_import(transactions_data, account_id) do
    periods = process_transactions_data(transactions_data, account_id)

    periods
    |> MapSet.to_list()
    |> Enum.each(fn {acc_id, month, year} ->
      Accounting.calculate_monthly_balance(acc_id, year, month)
    end)

    {:ok, length(transactions_data)}
  end

  defp process_transactions_data(transactions_data, account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # 1. Prepare all entries
    entries = Enum.map(transactions_data, &prepare_transaction_entry(&1, account_id, now))

    # 2. Batch Insert with on_conflict: :nothing
    # We use returning: true to get the actually inserted transactions for TransferMatcher
    {_count, inserted_transactions} = batch_insert_transactions(entries)

    # 3. Run TransferMatcher for new transactions in batch
    TransferMatcher.match_transfers(inserted_transactions)

    # 4. Collect affected periods for balance recalculation
    collect_affected_periods(transactions_data, account_id)
  end

  defp prepare_transaction_entry(data, account_id, now) do
    attrs =
      data
      |> Map.put(:account_id, account_id)
      |> AutoCategorizer.categorize()

    # Generate changeset to get fingerprint and validate
    changeset =
      Transaction.changeset(
        %Transaction{},
        attrs
      )

    # Merge changes with timestamps and a generated ID
    changeset.changes
    |> Map.put(:id, UUID.generate())
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  defp batch_insert_transactions(entries) do
    CashLens.Repo.insert_all(
      Transaction,
      entries,
      on_conflict: :nothing,
      conflict_target: :fingerprint,
      returning: true
    )
  end

  @special_account_names ["BB MM Ouro", "BB Rende Fácil"]

  defp collect_affected_periods(transactions_data, account_id) do
    special_accounts = Accounts.get_accounts_by_names(@special_account_names)

    Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
      acc = MapSet.put(acc, {account_id, data.date.month, data.date.year})
      add_special_account_periods(acc, data, special_accounts)
    end)
  end

  defp add_special_account_periods(acc, data, special_accounts) do
    description = String.upcase(data.description || "")

    cond do
      String.contains?(description, "BB MM OURO") ->
        add_account_period_if_exists(acc, special_accounts["BB MM Ouro"], data.date)

      String.contains?(description, ["BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
        add_account_period_if_exists(acc, special_accounts["BB Rende Fácil"], data.date)

      true ->
        acc
    end
  end

  defp add_account_period_if_exists(acc, account, date) do
    case account do
      nil -> acc
      a -> MapSet.put(acc, {a.id, date.month, date.year})
    end
  end
end
