defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  require Logger
  alias CashLens.Parsers.CSVParser
  alias CashLens.Parsers.PDFParser
  alias CashLens.Parsers.OFXParser
  alias CashLens.Accounts

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
    content = File.read!(file_path)

    content =
      cond do
        String.ends_with?(file_path, ".pdf") or account.parser_type == "sem_parar_pdf" ->
          case System.cmd("pdftotext", ["-layout", file_path, "-"]) do
            {text, 0} -> text
            _ -> content
          end

        String.ends_with?(file_path, [".ofx", ".OFX"]) or
            String.ends_with?(file_path, [".csv", ".CSV"]) ->
          if String.valid?(content),
            do: content,
            else: :unicode.characters_to_binary(content, :latin1, :utf8)

        true ->
          if String.valid?(content),
            do: content,
            else: :unicode.characters_to_binary(content, :latin1, :utf8)
      end

    case parse(content, account.parser_type) do
      {:error, reason} ->
        {:error, reason}

      transactions_data ->
        periods = process_transactions_data(transactions_data, account.id)

        periods
        |> MapSet.to_list()
        |> Enum.each(fn {acc_id, month, year} ->
          CashLens.Accounting.calculate_monthly_balance(acc_id, year, month)
        end)

        {:ok, length(transactions_data)}
    end
  end

  defp process_transactions_data(transactions_data, account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # 1. Prepare all entries
    entries =
      Enum.map(transactions_data, fn data ->
        attrs =
          data
          |> Map.put(:account_id, account_id)
          |> CashLens.Transactions.AutoCategorizer.categorize()

        # Generate changeset to get fingerprint and validate
        changeset =
          CashLens.Transactions.Transaction.changeset(
            %CashLens.Transactions.Transaction{},
            attrs
          )

        # Merge changes with timestamps and a generated ID
        changeset.changes
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    # 2. Batch Insert with on_conflict: :nothing
    # We use returning: true to get the actually inserted transactions for TransferMatcher
    {_count, inserted_transactions} =
      CashLens.Repo.insert_all(
        CashLens.Transactions.Transaction,
        entries,
        on_conflict: :nothing,
        conflict_target: :fingerprint,
        returning: true
      )

    # 3. Run TransferMatcher for new transactions
    Enum.each(inserted_transactions, fn tx ->
      CashLens.Transactions.TransferMatcher.match_transfer(tx)
    end)

    # 4. Collect affected periods for balance recalculation
    Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
      acc = MapSet.put(acc, {account_id, data.date.month, data.date.year})
      description = String.upcase(data.description || "")

      cond do
        String.contains?(description, "BB MM OURO") ->
          case Accounts.get_account_by_name("BB MM Ouro") do
            nil -> acc
            a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
          end

        String.contains?(description, ["BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
          case Accounts.get_account_by_name("BB Rende Fácil") do
            nil -> acc
            a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
          end

        true ->
          acc
      end
    end)
  end
end
