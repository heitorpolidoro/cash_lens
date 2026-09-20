defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  require Logger
  alias CashLens.Accounting
  alias CashLens.Imports
  alias CashLens.Parsers.CSVParser
  alias CashLens.Parsers.OFXParser
  alias CashLens.Parsers.OurocardTXTParser
  alias CashLens.Parsers.PDFParser
  alias CashLens.Transactions.AutoCategorizer
  alias CashLens.Transactions.Transaction
  alias CashLens.Transactions.TransferMatcher
  alias CashLens.Transactions.TransferRuleApplier
  alias Ecto.UUID
  import Ecto.Query, only: [from: 2]

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

      "mercadopago_cartao_pdf" ->
        Logger.info("Using Mercado Pago Cartao PDF Parser")
        PDFParser.parse(content, :mercado_pago_card)

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
      t when t in ["sem_parar_pdf", "bradesco_cartao_pdf", "mercadopago_cartao_pdf"] -> [".pdf"]
      "ourocard_txt" -> [".txt"]
      _ -> []
    end
  end

  @doc """
  Reads a file, converts encoding/extracts text, parses and saves the transactions.
  Returns `{:ok, count}` or `{:error, reason}`.

  With `dry_run: true`, computes the same `%{imported:, skipped:, failed:}`
  a real call on the same input would return, using the same fingerprint
  logic, but performs zero writes (no transaction rows, no credit-card
  statement, no balance rebuild). The dry run additionally carries a
  `:preview` key: one row per prepared entry, in file order, shaped
  `%{date:, time:, description:, amount:, category_id:, fingerprint:,
  status: :new | :duplicate}`. Rows that failed preparation never became
  entries and stay in `failed` instead. The real (non-dry-run) path does
  **not** carry `:preview` — it keeps returning the three-key map.
  """
  def import_file(account, file_path, opts \\ []) do
    notify_fn = Keyword.get(opts, :notify_fn)
    dry_run = Keyword.get(opts, :dry_run, false)

    case File.read(file_path) do
      {:ok, content} ->
        process_imported_content(content, account, file_path, notify_fn, dry_run, opts)

      {:error, reason} ->
        message = "Could not read file: #{reason}"
        if dry_run == false, do: record_import(account, file_path, opts, {:error, message}, nil)
        {:error, message}
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
    ext in [".csv", ".ofx", ".pdf", ".txt"]
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

  defp process_imported_content(raw_content, account, file_path, notify_fn, dry_run, opts) do
    content = prepare_content(raw_content, account, file_path)

    Logger.info("INGESTOR: #{account.parser_type} <- #{file_path} (#{account.name})")

    case parse(content, account.parser_type) do
      {:error, reason} ->
        Logger.error("INGESTOR: Parsing failed: #{reason}")
        # This branch is shared with the dry run (it sits above the `if dry_run`
        # below), so the recording carries an explicit non-dry-run guard.
        if dry_run == false, do: record_import(account, file_path, opts, {:error, reason}, nil)
        {:error, reason}

      transactions_data ->
        Logger.info("INGESTOR: Parser returned #{length(transactions_data)} transactions.")
        if notify_fn, do: notify_fn.(length(transactions_data))

        if dry_run do
          {result, _claimed} = preview_import(transactions_data, account.id, MapSet.new())
          result
        else
          statement_id =
            maybe_create_statement(account, content, file_path, transactions_data)

          {:ok, summary} = result = finalize_import(transactions_data, account.id, statement_id)
          record_import(account, file_path, opts, {:ok, summary}, raw_content)
          result
        end
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
         account.parser_type in ["sem_parar_pdf", "bradesco_cartao_pdf", "mercadopago_cartao_pdf"] do
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

  defp finalize_import(transactions_data, account_id, statement_id) do
    transactions_data = reject_future_dated(transactions_data)

    {entries, failed} = prepare_entries(transactions_data, account_id, statement_id)

    {inserted_count, affected_account_ids} =
      process_entries(entries, transactions_data, account_id, statement_id)

    # Rebuild balances for all affected accounts up to the current month/year
    Enum.each(affected_account_ids, fn acc_id ->
      Accounting.rebuild_account_balances(acc_id)
    end)

    # `skipped` makes silent dedupe misses observable: it is the number of prepared
    # input rows the unique index rejected as already-present (or in-batch dups),
    # i.e. entries that did not result in an insert. A future regression that lets
    # duplicates back in would surface as a non-zero `skipped` on re-import.
    skipped = length(entries) - inserted_count

    {:ok, %{imported: inserted_count, skipped: skipped, failed: failed}}
  end

  @doc """
  Same as `import_file/3` with `dry_run: true`, but for one file within a
  multi-file dry-run batch (a `DirectoryImporter` preview of an account
  folder holding several files). `claimed_fingerprints` is the set of
  fingerprints already counted as "would be newly imported" by earlier files
  in this same run; it is threaded through and returned updated so the next
  file in the folder sees it too.

  This mirrors what the real import does across files: file 1's rows land in
  the DB (via `on_conflict: :nothing`) before file 2's insert runs, so an
  overlapping row in file 2 is correctly skipped. A dry run writes nothing,
  so without this threading, file 2's preview can't see file 1's rows and
  double-counts them as new. Only `DirectoryImporter`'s dry-run path should
  call this; single-file callers use `import_file/3`.

  The returned summary carries the same `:preview` rows `import_file/3` with
  `dry_run: true` returns.
  """
  def preview_file(account, file_path, claimed_fingerprints) do
    case File.read(file_path) do
      {:ok, content} ->
        content = prepare_content(content, account, file_path)

        case parse(content, account.parser_type) do
          {:error, reason} ->
            {{:error, reason}, claimed_fingerprints}

          transactions_data ->
            preview_import(transactions_data, account.id, claimed_fingerprints)
        end

      {:error, reason} ->
        {{:error, "Could not read file: #{reason}"}, claimed_fingerprints}
    end
  end

  # Computes what a real import would do — same future-date filtering and
  # same `prepare_entries/3` (and therefore the same real dedup fingerprint)
  # `finalize_import/3` uses — but performs zero writes: no statement, no
  # transaction rows, no balance rebuild, no transfer/installment linking.
  # `imported` here means "would be newly imported"; `skipped` means "already
  # present" (a fingerprint that already exists in `transactions`, OR one
  # already claimed as new by an earlier file in this same dry-run batch via
  # `claimed_fingerprints`) — the same meaning `finalize_import/3`'s
  # `on_conflict: :nothing` insert would produce for the same input across
  # files. Returns `{{:ok, summary}, updated_claimed_fingerprints}`.
  defp preview_import(transactions_data, account_id, claimed_fingerprints) do
    transactions_data = reject_future_dated(transactions_data)

    {entries, failed} = prepare_entries(transactions_data, account_id, nil)

    already_present = existing_fingerprints(Enum.map(entries, & &1.fingerprint))

    {new_count, skipped_count, updated_claimed, reversed_preview} =
      Enum.reduce(entries, {0, 0, claimed_fingerprints, []}, fn entry,
                                                                {new, skipped, claimed, rows} ->
        if MapSet.member?(already_present, entry.fingerprint) or
             MapSet.member?(claimed, entry.fingerprint) do
          {new, skipped + 1, claimed, [preview_row(entry, :duplicate) | rows]}
        else
          {new + 1, skipped, MapSet.put(claimed, entry.fingerprint),
           [preview_row(entry, :new) | rows]}
        end
      end)

    summary = %{
      imported: new_count,
      skipped: skipped_count,
      failed: failed,
      preview: Enum.reverse(reversed_preview)
    }

    {{:ok, summary}, updated_claimed}
  end

  # One preview row per classified entry, derived from the very insert entry
  # the reduce above classified — never from a second parse. `:time` and
  # `:category_id` are optional: the entry is a changeset's `changes` map and
  # both keys are legitimately absent when the source row carries neither.
  defp preview_row(entry, status) do
    %{
      date: entry.date,
      time: Map.get(entry, :time),
      description: entry.description,
      amount: entry.amount,
      category_id: Map.get(entry, :category_id),
      fingerprint: entry.fingerprint,
      status: status
    }
  end

  # Never persist (or count as newly-importable) transactions dated in the
  # future — they have not happened yet. Shared by `finalize_import/3` and
  # `preview_import/3` so the real and dry-run paths can never silently
  # diverge on this rule.
  defp reject_future_dated(transactions_data) do
    today = Date.utc_today()
    Enum.reject(transactions_data, &(Date.compare(&1.date, today) == :gt))
  end

  defp existing_fingerprints([]), do: MapSet.new()

  defp existing_fingerprints(fingerprints) do
    CashLens.Repo.all(
      from(t in Transaction, where: t.fingerprint in ^fingerprints, select: t.fingerprint)
    )
    |> MapSet.new()
  end

  defp prepare_entries(transactions_data, account_id, statement_id) do
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

    entries = Enum.map(valid, fn {:ok, entry} -> entry end)
    reasons = Enum.map(failed, fn {:error, reason} -> reason end)
    {entries, reasons}
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

  # Records one executed file import in `CashLens.Imports`. Called from exactly
  # three places in `import_file/3`'s path — the unreadable-file branch, the
  # parse-error branch (guarded by `dry_run == false`, since it is shared with
  # the dry run) and the non-dry-run finalization branch — and from nowhere
  # else. `preview_file/3` is never instrumented.
  #
  # Recording must never fail an import: any error is logged and the caller's
  # original return value is preserved byte-for-byte.
  defp record_import(account, file_path, opts, outcome, raw_content) do
    ran_at = DateTime.utc_now() |> DateTime.truncate(:second)
    path_key = Imports.relative_path(file_path, Imports.import_root(opts))

    base = %{ran_at: ran_at, account_id: account.id, file_path: path_key}

    base
    |> Map.merge(run_attrs(outcome, path_key, file_path, raw_content, ran_at))
    |> Imports.record_run()
    |> log_record_failure(file_path)
  rescue
    e -> Logger.error("INGESTOR: could not record import run: #{Exception.message(e)}")
  end

  defp run_attrs({:error, reason}, _path_key, _file_path, _raw_content, _ran_at) do
    %{
      status: "error",
      imported_count: 0,
      skipped_count: 0,
      failed_count: 0,
      error_message: to_string(reason)
    }
  end

  defp run_attrs({:ok, summary}, path_key, file_path, raw_content, ran_at) do
    %{
      status: if(summary.failed == [], do: "success", else: "warning"),
      imported_count: summary.imported,
      skipped_count: Map.get(summary, :skipped, 0),
      failed_count: length(summary.failed),
      imported_file_id: touch_imported_file(path_key, file_path, raw_content, ran_at)
    }
  end

  # The hash is taken over the *raw* bytes read from disk, before
  # `prepare_content/3` normalizes encoding or extracts PDF text, so the value
  # matches what `Imports.scan/1` measures on the same file.
  defp touch_imported_file(path_key, file_path, raw_content, ran_at) do
    attrs = %{
      path: path_key,
      content_hash: raw_content && Imports.content_hash(raw_content),
      mtime: Imports.file_mtime(file_path),
      last_imported_at: ran_at
    }

    case Imports.upsert_imported_file(attrs) do
      {:ok, imported_file} -> imported_file.id
      {:error, _changeset} -> nil
    end
  end

  defp log_record_failure({:error, changeset}, file_path) do
    Logger.error("INGESTOR: could not record import run for #{file_path}: #{inspect(changeset)}")
  end

  defp log_record_failure(other, _file_path), do: other

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
