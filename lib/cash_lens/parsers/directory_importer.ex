defmodule CashLens.Parsers.DirectoryImporter do
  @moduledoc """
  Imports statement files from a directory, routing each folder to the account
  declared in its `.account` file. Reusable by both the mix task and the web UI.
  """
  alias CashLens.Accounts
  alias CashLens.Parsers.AccountFile
  alias CashLens.Parsers.Ingestor

  defmodule Result do
    @moduledoc "Structured outcome of a directory import."
    defstruct accounts: [], warnings: [], errors: []
  end

  @supported_extensions ~w(.csv .ofx .pdf)

  @doc """
  Imports a directory. Options:
    * `:skip_installments` — when true, does not run installment detection
      (used in tests to keep cases isolated).
  """
  def run(path, opts \\ []) do
    if File.dir?(path) do
      run_existing(path, opts)
    else
      %Result{errors: ["caminho '#{path}' não existe ou não é uma pasta"]}
    end
  end

  defp run_existing(path, opts) do
    emit = Keyword.get(opts, :on_event, fn _ -> :ok end)
    {account_dirs, skipped_dirs} = classify(path)

    emit.({:start, length(account_dirs)})

    result =
      account_dirs
      |> Enum.reduce(%Result{}, fn dir, acc -> import_account_folder(dir, path, acc, emit) end)
      |> add_skipped_warnings(skipped_dirs)

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
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

  defp import_account_folder(dir, root_path, result, emit) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, root_path, account, bank, name, result, emit)
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

  defp do_import(dir, root_path, account, bank, name, result, emit) do
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
          case Ingestor.import_file(account, file) do
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
    %{result | accounts: result.accounts ++ [entry]}
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
