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
      |> Enum.reduce(%Result{}, fn dir, acc -> import_account_folder(dir, acc, emit) end)
      |> add_skipped_warnings(skipped_dirs)

    unless Keyword.get(opts, :skip_installments, false) do
      CashLens.Installments.scan_and_apply_all()
    end

    result
  end

  # A path that itself has a `.account` is a single account folder. Otherwise its
  # immediate subdirectories are split into those with a `.account` (to import)
  # and those without (skipped with a warning).
  defp classify(path) do
    if AccountFile.exists?(path) do
      {[path], []}
    else
      path
      |> File.ls!()
      |> Enum.map(&Path.join(path, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort()
      |> Enum.split_with(&AccountFile.exists?/1)
    end
  end

  defp add_skipped_warnings(result, dirs) do
    Enum.reduce(dirs, result, fn dir, acc ->
      add_warning(acc, "pasta #{Path.basename(dir)}/ sem .account — pulada")
    end)
  end

  defp import_account_folder(dir, result, emit) do
    with {:ok, %{bank: bank, account: name}} <- AccountFile.read(dir),
         {:ok, account} <- resolve_account(bank, name) do
      do_import(dir, account, bank, name, result, emit)
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

  defp do_import(dir, account, bank, name, result, emit) do
    label = "#{bank} / #{name}"
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

    entry = Map.merge(summary, %{account: account, bank: bank, name: name})
    %{result | accounts: result.accounts ++ [entry]}
  end

  defp partition_files(dir, expected) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&(File.regular?(&1) and extname(&1) in @supported_extensions))
    |> Enum.split_with(&(extname(&1) in expected))
  end

  defp extname(path), do: path |> Path.extname() |> String.downcase()

  defp add_warning(result, msg), do: %{result | warnings: result.warnings ++ [msg]}
  defp add_error(result, msg), do: %{result | errors: result.errors ++ [msg]}
end
