defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  require Logger
  alias CashLens.Accounting
  alias CashLens.Parsers.CSVParser
  alias CashLens.Parsers.OFXParser
  alias CashLens.Parsers.OurocardTXTParser
  alias CashLens.Parsers.PDFParser
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRuleApplier
  alias Ecto.UUID

  @doc """
  Parses the content based on the provided parser_type.
  """
  def parse(content, parser_type) do
    case parser_type do
      "bradesco_csv" ->
        Logger.info("Using Bradesco CSV Parser")
        CSVParser.parse(content, :bradesco_csv)

      "bb_csv" ->
        Logger.info("Using BB CSV Parser")
        CSVParser.parse(content, :bb)

      "mercado_pago_csv" ->
        Logger.info("Using Mercado Pago CSV Parser")
        CSVParser.parse(content, :mercado_pago_csv)

      "sem_parar_pdf" ->
        Logger.info("Using Sem Parar PDF Parser")
        PDFParser.parse(content, :sem_parar)

      "bradesco_cartao_pdf" ->
        Logger.info("Using Bradesco Cartao PDF Parser")
        PDFParser.parse(content, :bradesco_card)

      "standard_ofx" ->
        Logger.info("Using Standard OFX Parser")
        OFXParser.parse(content, :standard)

      "ourocard_ofx" ->
        Logger.info("Using Ourocard OFX Parser")
        OFXParser.parse(content, :ourocard)

      "ourocard_txt" ->
        Logger.info("Using Ourocard TXT Parser")
        OurocardTXTParser.parse(content, :ourocard)

      _ ->
        {:error, "Extrator não configurado ou não suportado para esta conta."}
    end
  end

  @doc """
  Returns the file extensions a given parser_type can handle. Used to guard
  against feeding e.g. an .ofx file to a CSV parser during folder imports.
  """
  def expected_extensions(parser_type) do
    case parser_type do
      t when t in ["bradesco_csv", "bb_csv", "mercado_pago_csv"] -> [".csv"]
      t when t in ["ourocard_ofx", "standard_ofx"] -> [".ofx"]
      t when t in ["sem_parar_pdf", "bradesco_cartao_pdf"] -> [".pdf"]
      "ourocard_txt" -> [".txt"]
      _ -> []
    end
  end

  @doc """
  Reads a file, converts encoding/extracts text, parses and saves the transactions.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def import_file(account, file_path, opts \\ []) do
    notify_fn = Keyword.get(opts, :notify_fn)

    case File.read(file_path) do
      {:ok, content} ->
        process_imported_content(content, account, file_path, notify_fn)

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

    total_imported = successes |> Enum.map(fn {:ok, %{imported: n}} -> n end) |> Enum.sum()

    total_skipped =
      successes |> Enum.map(fn {:ok, s} -> Map.get(s, :skipped, 0) end) |> Enum.sum()

    all_failed = successes |> Enum.flat_map(fn {:ok, %{failed: f}} -> f end)

    if Enum.empty?(errors) do
      {:ok, %{imported: total_imported, skipped: total_skipped, failed: all_failed}}
    else
      {:error,
       "#{length(errors)} files failed to import. Total transactions from successful files: #{total_imported}"}
    end
  end

  defp process_imported_content(content, account, file_path, notify_fn) do
    content = prepare_content(content, account, file_path)

    Logger.info("INGESTOR: #{account.parser_type} <- #{file_path} (#{account.name})")

    case parse(content, account.parser_type) do
      {:error, reason} ->
        Logger.error("INGESTOR: Parsing failed: #{reason}")
        {:error, reason}

      transactions_data ->
        Logger.info("INGESTOR: Parser returned #{length(transactions_data)} transactions.")
        if notify_fn, do: notify_fn.(length(transactions_data))

        statement_id =
          maybe_create_statement(account, content, file_path, transactions_data)

        finalize_import(transactions_data, account.id, account.is_credit_card, statement_id)
    end
  end

  # Returns the new statement id for credit-card accounts (so rows can be
  # stamped and matched), or nil for regular accounts.
  defp maybe_create_statement(%{is_credit_card: true} = account, content, file_path, transactions) do
    meta = statement_meta(content, file_path)

    {:ok, statement} =
      CashLens.CreditCards.create_statement(%{
        account_id: account.id,
        due_date: meta.due_date,
        total_a_pagar: meta.total_a_pagar,
        competencia: CashLens.CreditCards.competencia_for(account, meta, transactions),
        source_file: Path.basename(file_path)
      })

    statement.id
  end

  defp maybe_create_statement(_account, _content, _file_path, _transactions), do: nil

  # Statement metadata (due date, total, competência) extracted from the file,
  # by source format. OFX carries a ledger balance; PDF a Vencimento + total;
  # anything else has none.
  def statement_meta(content, file_path) do
    cond do
      String.ends_with?(file_path, ".pdf") -> PDFParser.extract_statement_meta(content)
      String.ends_with?(file_path, ".ofx") -> OFXParser.extract_statement_meta(content)
      String.ends_with?(file_path, ".txt") -> OurocardTXTParser.extract_statement_meta(content)
      true -> %{due_date: nil, total_a_pagar: nil, competencia: nil}
    end
  end

  @doc """
  Reads and normalizes a file's content exactly like the importer does before
  parsing: PDF text extraction via the configured converter for `.pdf` files
  (or PDF-only parser types), UTF-8 normalization otherwise. Exposed so other
  callers (e.g. the backfill mix task) reproduce identical parser input.
  """
  def prepare_content(content, account, file_path) do
    if String.ends_with?(file_path, ".pdf") or
         account.parser_type in ["sem_parar_pdf", "bradesco_cartao_pdf"] do
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

  defp finalize_import(transactions_data, account_id, credit_card?, statement_id) do
    # Never persist transactions dated in the future — they have not happened yet.
    today = Date.utc_today()
    transactions_data = Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))

    {entries, failed, cross_source_skipped} =
      prepare_entries(transactions_data, account_id, credit_card?, statement_id)

    {inserted_count, affected_account_ids} =
      process_entries(entries, transactions_data, account_id, statement_id)

    # Rebuild balances for all affected accounts up to the current month/year
    Enum.each(affected_account_ids, fn acc_id ->
      Accounting.rebuild_account_balances(acc_id)
    end)

    # `skipped` makes silent dedupe misses observable: it is the number of prepared
    # input rows that did not result in an insert — either the unique index rejected
    # them as already-present (or in-batch dups) via `fingerprint`, or they were
    # filtered out beforehand as a cross-source duplicate (see
    # `cross_source_duplicate?/5`).
    skipped = length(entries) - inserted_count + cross_source_skipped

    {:ok, %{imported: inserted_count, skipped: skipped, failed: failed}}
  end

  defp prepare_entries(transactions_data, account_id, credit_card?, statement_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {valid, failed} =
      transactions_data
      |> assign_occurrence_indices(account_id)
      |> Enum.map(fn {data, index} ->
        try do
          {:ok, prepare_transaction_entry(data, account_id, now, index, statement_id)}
        rescue
          e -> {:error, {data[:description] || "unknown", Exception.message(e)}}
        end
      end)
      |> Enum.split_with(fn
        {:ok, _} -> true
        _ -> false
      end)

    all_entries = Enum.map(valid, fn {:ok, entry} -> entry end)
    reasons = Enum.map(failed, fn {:error, reason} -> reason end)

    {entries, cross_source_dupes} =
      Enum.split_with(all_entries, fn entry ->
        account_id = Map.get(entry, :account_id)
        date = Map.get(entry, :date)
        amount = Map.get(entry, :amount)
        description = Map.get(entry, :description)

        if is_nil(account_id) or is_nil(date) or is_nil(amount) do
          true
        else
          if cross_source_duplicate?(account_id, date, amount, description, credit_card?) do
            Logger.warning(
              "Ingestor: skipping transaction as cross-source duplicate for account #{account_id} " <>
                "on #{date} (amount #{amount}, description #{inspect(description)}); " <>
                "existence-based match may skip more rows than actually duplicated"
            )

            false
          else
            true
          end
        end
      end)

    {entries, reasons, length(cross_source_dupes)}
  end

  # Installment identity (parcel number + total + merchant + amount, within a
  # coarse date window) is checked first since it is more precise than plain
  # date matching for "PARC X/Y" rows — see
  # `Transactions.duplicate_installment_from_other_source?/5`'s moduledoc for
  # why date matching alone cannot reliably catch these. Falls back to the
  # date-based check (with the credit-card ±1 day window) for everything else.
  defp cross_source_duplicate?(account_id, date, amount, description, credit_card?) do
    CashLens.Transactions.duplicate_installment_from_other_source?(
      account_id,
      date,
      description,
      amount,
      "file"
    ) or
      CashLens.Transactions.duplicate_from_other_source?(
        account_id,
        date,
        amount,
        "file",
        credit_card?
      )
  end

  # Computes the 0-based occurrence index of every incoming row among otherwise
  # identical rows (same dedup_key) *within this batch*, preserving input order.
  #
  # The index is the batch position only — the count of already-stored rows is
  # deliberately NOT added. That is what makes re-import dedupe correct: the N
  # identical lines of a statement always reproduce indices 0..N-1, so on
  # re-import they regenerate the exact fingerprints already on disk and the
  # unique index drops them (zero duplicates). Genuinely-distinct identical
  # lines that arrive together in one statement get distinct indices (0, 1, …)
  # and are all preserved.
  #
  # Cross-statement repeats (the same single line appearing again in a later,
  # separate import) collapse to index 0 and therefore collide with the stored
  # row — they are treated as duplicates. This is the intended, re-import-safe
  # default; the system cannot tell such a repeat apart from a true re-import,
  # so it errs toward not creating a duplicate.
  defp assign_occurrence_indices(transactions_data, account_id) do
    {tagged, _seen} =
      Enum.map_reduce(transactions_data, %{}, fn data, seen ->
        key = dedup_key_for(data, account_id)
        index = Map.get(seen, key, 0)
        {{data, index}, Map.put(seen, key, index + 1)}
      end)

    tagged
  end

  defp dedup_key_for(data, account_id) do
    data
    |> Map.put(:account_id, account_id)
    |> Transaction.dedup_key()
  end

  defp process_entries(entries, _transactions_data, account_id, statement_id) do
    # 2. Batch Insert with on_conflict: :nothing
    # We use returning: true to get the actually inserted transactions for TransferMatcher.
    # `count` is the number of rows actually inserted (conflicts are not counted),
    # which lets the caller compute how many input rows were skipped as duplicates.
    {count, inserted_transactions} = batch_insert_transactions(entries)

    # 3. Apply transfer rules for newly inserted transactions, creating mirrors as needed
    mirror_transactions = TransferRuleApplier.apply_rules(inserted_transactions)

    # 3b. Try to link a freshly-imported credit-card invoice batch to an
    # existing "Cartão de Crédito" payment transaction.
    if statement_id do
      statement = CashLens.CreditCards.get_statement!(statement_id)
      CashLens.CreditCards.absorb_pending(statement)

      line_total =
        Enum.reduce(inserted_transactions, Decimal.new(0), &Decimal.add(&2, &1.amount))

      CashLens.CreditCards.Matcher.auto_link(statement, line_total)
    end

    # 4. Run TransferMatcher for new transactions (including mirrors) in batch
    matched_account_ids =
      TransferMatcher.match_transfers(inserted_transactions ++ mirror_transactions) || []

    # Note: installment detection runs once over the full set after the whole batch
    # import (see ImportModalComponent), because a purchase's parcels can span
    # multiple monthly statements and must be grouped together.

    # 5. Collect affected account IDs for balance rebuilding
    mirror_account_ids = Enum.map(mirror_transactions, & &1.account_id)

    all_affected_account_ids =
      [account_id | mirror_account_ids ++ matched_account_ids]
      |> Enum.uniq()

    {count, all_affected_account_ids}
  end

  defp prepare_transaction_entry(data, account_id, now, occurrence_index, statement_id) do
    categorizer = Application.get_env(:cash_lens, :auto_categorizer, AutoCategorizer)

    attrs =
      data
      |> Map.put(:account_id, account_id)
      |> Map.put(:occurrence_index, occurrence_index)
      |> Map.put(:source, "file")
      |> categorizer.categorize()

    # Generate changeset to get fingerprint and validate
    changeset =
      Transaction.changeset(
        %Transaction{},
        attrs
      )

    # Merge changes with timestamps and a generated ID. `occurrence_index` is a
    # virtual field (an input to the fingerprint only) and must not reach
    # `insert_all`, which rejects non-column fields.
    changeset.changes
    |> Map.drop([:occurrence_index])
    |> Map.put(:id, UUID.generate())
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
    |> Map.put(:import_batch_id, statement_id)
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
end
