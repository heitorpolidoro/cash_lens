defmodule CashLens.Parsers.DirectoryImporter do
  @moduledoc """
  Imports statement files from a directory, routing each folder to the account
  declared in its `.account` file. Reusable by both the mix task and the web UI.
  """
  alias CashLens.Accounts
  alias CashLens.Parsers.AccountFile
  alias CashLens.Parsers.Ingestor

  @doc """
  Scans `path` for `.account` files and checks whether all referenced accounts
  exist. Returns:

    * `:ok`                              — all accounts found, safe to `run/2`
    * `{:needs_confirmation, [attrs]}`   — some accounts missing but parsers valid;
                                           each entry has `:bank`, `:account`, `:parser`, `:credit_card`
    * `{:error, [reason]}`              — one or more `.account` files have invalid parsers
  """
  def preflight(path) do
    if File.dir?(path) do
      {account_dirs, _skipped} = classify(path)

      {errors, missing} =
        Enum.reduce(account_dirs, {[], []}, fn dir, {errs, miss} ->
          case AccountFile.read(dir) do
            {:error, reason} ->
              {[reason | errs], miss}

            {:ok, attrs} ->
              case AccountFile.validate_parser(attrs) do
                {:error, reason} ->
                  {[reason | errs], miss}

                :ok ->
                  case Accounts.find_accounts_by_bank_and_name(attrs.bank, attrs.account) do
                    [_] -> {errs, miss}
                    _ -> {errs, [attrs | miss]}
                  end
              end
          end
        end)

      cond do
        errors != [] -> {:error, Enum.reverse(errors)}
        missing != [] -> {:needs_confirmation, Enum.reverse(missing)}
        true -> :ok
      end
    else
      {:error, ["caminho '#{path}' não existe ou não é uma pasta"]}
    end
  end

  defmodule Result do
    @moduledoc "Structured outcome of a directory import."
    defstruct accounts: [], warnings: [], errors: [], cycle_warnings: []
  end

  @supported_extensions ~w(.csv .ofx .pdf .txt)

  @doc """
  Imports a directory. Options:
    * `:skip_installments` — when true, does not run installment detection
      (used in tests to keep cases isolated).
    * `:create_missing` — when true, creates accounts referenced in `.account`
      files that do not yet exist in the database (call `preflight/1` first and
      confirm with the user before passing this option).
    * `:dry_run` — when true, computes the same per-account counts a real run
      would, with zero writes (no transactions, no statements, no balance
      rebuild, no installment scan — regardless of `:skip_installments`).
  """
  def run(path, opts \\ []) do
    if File.dir?(path) do
      run_existing(path, opts)
    else
      %Result{errors: ["caminho '#{path}' não existe ou não é uma pasta"]}
    end
  end

  defp run_existing(path, opts) do
    if Keyword.get(opts, :create_missing, false) do
      create_missing_accounts(path)
    end

    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    dry_run = Keyword.get(opts, :dry_run, false)
    {account_dirs, skipped_dirs} = classify(path)

    emit.({:start, length(account_dirs)})

    result =
      account_dirs
      |> Enum.reduce(%Result{}, fn dir, acc ->
        import_account_folder(dir, path, acc, emit, dry_run)
      end)
      |> add_skipped_warnings(skipped_dirs)

    unless dry_run or Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end

  defp create_missing_accounts(path) do
    {account_dirs, _} = classify(path)

    Enum.each(account_dirs, fn dir ->
      with {:ok, attrs} <- AccountFile.read(dir),
           :ok <- AccountFile.validate_parser(attrs),
           [] <- Accounts.find_accounts_by_bank_and_name(attrs.bank, attrs.account) do
        Accounts.create_account(%{
          name: attrs.account,
          bank: attrs.bank,
          parser_type: attrs.parser,
          is_credit_card: attrs.credit_card,
          balance: 0,
          accepts_import: true,
          is_closed: false
        })
      end
    end)
  end

  # A path that itself has a `.account` is a single account folder. Otherwise,
  # it recursively traverses subdirectories looking for `.account` files.
  # Subfolders without `.account` that contain supported files are skipped with a warning.
  defp classify(path) do
    if AccountFile.exists?(path) do
      {[path], []}
    else
      {account_dirs, skipped_dirs} = traverse(path, [], [])
      {Enum.reverse(account_dirs), Enum.reverse(skipped_dirs)}
    end
  end

  defp traverse(path, account_dirs, skipped_dirs) do
    if AccountFile.exists?(path) do
      {[path | account_dirs], skipped_dirs}
    else
      skipped_dirs = maybe_warn_skipped_dir(path, skipped_dirs)

      case File.ls(path) do
        {:ok, items} ->
          traverse_children(path, items, account_dirs, skipped_dirs)

        _ ->
          {account_dirs, skipped_dirs}
      end
    end
  end

  defp traverse_children(path, items, account_dirs, skipped_dirs) do
    items
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.reduce({account_dirs, skipped_dirs}, fn subdir, {acc_dirs, sk_dirs} ->
      traverse(subdir, acc_dirs, sk_dirs)
    end)
  end

  defp maybe_warn_skipped_dir(path, skipped_dirs) do
    if has_supported_files?(path) do
      [path | skipped_dirs]
    else
      skipped_dirs
    end
  end

  defp has_supported_files?(path) do
    case File.ls(path) do
      {:ok, files} ->
        Enum.any?(files, fn f ->
          full_path = Path.join(path, f)
          File.regular?(full_path) and extname(full_path) in @supported_extensions
        end)

      _ ->
        false
    end
  end

  defp add_skipped_warnings(result, dirs) do
    Enum.reduce(dirs, result, fn dir, acc ->
      add_warning(acc, "pasta #{Path.basename(dir)}/ sem .account — pulada")
    end)
  end

  defp import_account_folder(dir, root_path, result, emit, dry_run) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, root_path, account, bank, name, result, emit, dry_run)
    else
      {:error, reason} ->
        add_error(result, "pasta #{Path.basename(dir)}/ — #{reason}")
    end
  end

  defp resolve_account(bank, name) do
    case Accounts.find_accounts_by_bank_and_name(bank, name) do
      [account] -> {:ok, account}
      [] -> {:error, "conta '#{bank} / #{name}' não encontrada"}
      _ -> {:error, "conta '#{bank} / #{name}' é ambígua"}
    end
  end

  defp do_import(dir, root_path, account, bank, name, result, emit, dry_run) do
    label = format_label(dir, root_path)
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, mismatched} = partition_files(dir, expected)

    result =
      Enum.reduce(mismatched, result, fn file, acc ->
        add_warning(
          acc,
          "arquivo #{Path.basename(file)} não corresponde ao parser #{account.parser_type} — ignorado"
        )
      end)

    emit.({:account_start, label, length(matching)})

    summary =
      Enum.reduce(matching, %{imported: 0, skipped: 0, failed: []}, fn file, acc ->
        acc =
          case Ingestor.import_file(account, file, dry_run: dry_run) do
            {:ok, s} ->
              %{
                imported: acc.imported + s.imported,
                skipped: acc.skipped + Map.get(s, :skipped, 0),
                failed: acc.failed ++ Map.get(s, :failed, [])
              }

            {:error, reason} ->
              %{acc | failed: acc.failed ++ [{Path.basename(file), reason}]}
          end

        emit.({:file_done, label})
        acc
      end)

    emit.({:account_done, summary})

    entry = Map.merge(summary, %{account: account, bank: bank, name: name, folder_path: label})

    statements = CashLens.CreditCards.list_boletos_for_account(account.id)
    divergences = cycle_divergences(account, statements)

    %{
      result
      | accounts: result.accounts ++ [entry],
        cycle_warnings: result.cycle_warnings ++ divergences
    }
  end

  @doc false
  # Compares each statement's due_date day against the account's configured
  # due_day, returning one divergence entry per mismatch. Statements without a
  # due_date (non-boleto statements) are ignored, as is an account without a
  # configured due_day. Public (but undocumented) so it can be exercised
  # directly in tests.
  def cycle_divergences(%{due_day: nil}, _statements), do: []

  def cycle_divergences(account, statements) do
    statements
    |> Enum.filter(&(&1.due_date != nil and &1.due_date.day != account.due_day))
    |> Enum.map(fn s ->
      %{
        account_id: account.id,
        account_name: account.name,
        file: s.source_file,
        file_due_day: s.due_date.day,
        configured_due_day: account.due_day
      }
    end)
  end

  @doc """
  Walks `path`'s `.account` folder structure exactly like `run/2` does, but
  only visits credit-card accounts, and instead of importing calls
  `fun.(account, content, file_path)` for each of that account's files whose
  extension matches its parser. `content` is prepared the same way `run/2`
  prepares it (PDF text extraction via the configured converter, or UTF-8
  normalization) so parsing reproduces the original import exactly.

  Used by the backfill mix task, which needs the parsed rows and file
  metadata without re-inserting transactions.
  """
  def each_credit_card_file(path, fun) do
    if File.dir?(path) do
      {account_dirs, _skipped} = classify(path)

      Enum.each(account_dirs, fn dir ->
        with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
             {:ok, account} <- resolve_account(bank, name),
             true <- account.is_credit_card do
          visit_account_files(dir, account, fun)
        else
          _ -> :ok
        end
      end)
    else
      {:error, "caminho '#{path}' não existe ou não é uma pasta"}
    end
  end

  defp visit_account_files(dir, account, fun) do
    expected = Ingestor.expected_extensions(account.parser_type)
    {matching, _mismatched} = partition_files(dir, expected)

    Enum.each(matching, fn file_path ->
      with {:ok, raw} <- File.read(file_path) do
        content = Ingestor.prepare_content(raw, account, file_path)
        fun.(account, content, file_path)
      end
    end)
  end

  defp format_label(dir, root_path) do
    basename = Path.basename(dir)

    if String.match?(basename, ~r/^\d{4}$/) do
      parent = Path.dirname(dir)
      Path.join(Path.basename(parent), basename)
    else
      if dir == root_path do
        Path.basename(dir)
      else
        Path.relative_to(dir, root_path)
      end
    end
  end

  # Recursive: an account folder commonly has files organized into year/month
  # subfolders (e.g. "BB Conta Corrente/2026/junho.csv") with a single `.account`
  # at the top, not one per subfolder. A non-recursive listing would silently
  # skip everything below the first level.
  defp partition_files(dir, expected) do
    Path.join(dir, "**/*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and extname(&1) in @supported_extensions))
    |> Enum.split_with(&(extname(&1) in expected))
  end

  defp extname(path), do: path |> Path.extname() |> String.downcase()

  defp add_warning(result, msg), do: %{result | warnings: result.warnings ++ [msg]}
  defp add_error(result, msg), do: %{result | errors: result.errors ++ [msg]}
end
