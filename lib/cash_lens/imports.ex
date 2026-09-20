defmodule CashLens.Imports do
  @moduledoc """
  Tracks which statement files have already been ingested and keeps the history
  of executed imports.

  Two tables back this context:

    * `imported_files` — one row per statement file, holding the content hash
      and filesystem mtime measured at the last successful import, plus when
      that import happened;
    * `import_runs` — one row per executed (never dry-run) file import, with
      its status and counts.

  ## Path keys

  A file's key is **relative to the monitored root** whenever one is
  configured. The root is a Google Drive mount whose absolute path contains
  spaces and the user's email and can be remounted elsewhere; keying rows
  absolutely would turn a remount into a full re-import. When no root can be
  resolved (ad-hoc single-file imports) the row is keyed by its absolute path
  instead, and `scan/1` looks every discovered file up under *both* keys —
  relative first — so a row written under one key is never missed under the
  other.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias CashLens.Accounts
  alias CashLens.Imports.ImportedFile
  alias CashLens.Imports.ImportRun
  alias CashLens.Parsers.AccountFile
  alias CashLens.Parsers.DirectoryImporter
  alias CashLens.Parsers.FormatDetector
  alias CashLens.Parsers.Ingestor
  alias CashLens.Repo
  alias CashLens.Settings

  require Logger

  @root_setting "last_batch_import_path"

  # Every dropped file is staged under this directory of the system tmp dir.
  @drop_dir "cash_lens_drops"

  # A session staging directory untouched for this long belonged to a session
  # that never got to run `terminate/2`.
  @stale_after 24 * 60 * 60

  @doc """
  Compares the monitored root on disk against what has already been imported.

  Returns `{:ok, entries}` sorted by `path`, or `{:error, :not_a_directory}`
  when `root` is not a directory. Each entry is a map with the keys `:path`,
  `:absolute_path`, `:account_dir`, `:bank`, `:account`, `:status`,
  `:content_hash`, `:mtime` and `:last_imported_at`, where `:status` is:

    * `:new`     — no `imported_files` row for this file;
    * `:updated` — the recorded `content_hash` **or** `mtime` differs from disk;
    * `:synced`  — both match.

  Only files under a directory tree marked by a `.account` file are returned,
  and only those whose extension matches the account's `parser_type` — a
  mismatched file is never imported by `DirectoryImporter.run/2`, so listing it
  would show a row stuck at `:new` forever. Unreadable files are logged and
  omitted. A recorded path that no longer exists on disk simply does not
  appear (its row is deliberately kept: the file may come back from the mount).
  """
  def scan(root) when is_binary(root) do
    if File.dir?(root) do
      {:ok, do_scan(root)}
    else
      {:error, :not_a_directory}
    end
  end

  def scan(_root), do: {:error, :not_a_directory}

  @doc """
  Resolves the monitored root from `opts`: the `:import_root` option when it is
  a non-blank binary, otherwise the `"#{@root_setting}"` setting when non-blank,
  otherwise `nil`.

  A blank root normalizes to `nil` and never to `Path.expand("")`, so the
  current working directory can never become an accidental root.
  """
  def import_root(opts) do
    case normalize_root(Keyword.get(opts, :import_root)) do
      nil -> normalize_root(Settings.get(@root_setting, ""))
      root -> root
    end
  end

  @doc """
  Persists the monitored root, writing the same setting key `import_root/1`
  reads so the scanned folder and the `imported_files` path key can never
  disagree.

  The value is trimmed; a blank path is rejected with `:error` and nothing is
  written.
  """
  def put_import_root(root) when is_binary(root) do
    case String.trim(root) do
      "" ->
        :error

      trimmed ->
        Settings.put(@root_setting, trimmed)
        {:ok, trimmed}
    end
  end

  def put_import_root(_root), do: :error

  @doc """
  The monitored root to fall back to when no setting has been saved yet.

  Expanded, so the screen shows an absolute path the operator can recognise.
  """
  def default_import_root do
    :cash_lens
    |> Application.get_env(:default_import_root, "~/CashLens/extratos")
    |> Path.expand()
  end

  @doc """
  The `imported_files.path` key for `abs_path` under `root`.

  Returns a root-relative path when `root` is a non-blank binary and the file
  lives under it; otherwise the expanded absolute path.
  """
  def relative_path(abs_path, root) do
    expanded = Path.expand(abs_path)

    case normalize_root(root) do
      nil -> expanded
      root -> Path.relative_to(expanded, Path.expand(root))
    end
  end

  @doc "The content hash of a file's raw bytes: lowercase hex SHA-256."
  def content_hash(raw_bytes) when is_binary(raw_bytes) do
    :crypto.hash(:sha256, raw_bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  The filesystem mtime of `path` as a second-truncated UTC `DateTime`, or `nil`
  when the file cannot be stat'ed. POSIX mtime is already UTC; no local
  timezone is ever consulted, on write or on compare.
  """
  def file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime |> DateTime.from_unix!() |> DateTime.truncate(:second)
      {:error, _reason} -> nil
    end
  end

  @doc "Fetches the `imported_files` row for a path key, or `nil`."
  def get_imported_file_by_path(path) when is_binary(path) do
    Repo.get_by(ImportedFile, path: path)
  end

  @doc "Fetches the `imported_files` rows for a list of path keys, indexed by path."
  def map_by_paths([]), do: %{}

  def map_by_paths(paths) when is_list(paths) do
    ImportedFile
    |> where([f], f.path in ^paths)
    |> Repo.all()
    |> Map.new(&{&1.path, &1})
  end

  @doc """
  Inserts or refreshes the `imported_files` row for `attrs.path`.

  The hash, mtime and `last_imported_at` are always replaced with the values
  freshly measured from disk: for an unchanged file the first two are identical
  to what was stored, so the only visible effect is a refreshed
  `last_imported_at`. There is no "leave the old hash" case.
  """
  def upsert_imported_file(attrs) do
    %ImportedFile{}
    |> ImportedFile.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:content_hash, :mtime, :last_imported_at, :updated_at]},
      conflict_target: :path,
      returning: true
    )
  end

  @doc "Records one executed file import in the history."
  def record_run(attrs) do
    %ImportRun{}
    |> ImportRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc "The most recent runs, newest first, with their account preloaded."
  def list_recent_runs(limit \\ 20) do
    Repo.all(
      from(r in ImportRun,
        order_by: [desc: r.ran_at, desc: r.inserted_at],
        limit: ^limit,
        preload: [:account]
      )
    )
  end

  @doc """
  Resolves the `CashLens.Accounts.Account` a `scan/1` entry belongs to, from its
  `:bank` and `:account` strings.

  Returns `{:ok, account}`, `{:error, :not_found}` or `{:error, :ambiguous}`.
  This is the same resolution `DirectoryImporter` performs for a folder import,
  kept in the context so the web layer never queries `CashLens.Accounts`
  directly and a preview always targets the account a real import would use.
  """
  def account_for_entry(%{bank: bank, account: name})
      when is_binary(bank) and is_binary(name) do
    case Accounts.find_accounts_by_bank_and_name(bank, name) do
      [account] -> {:ok, account}
      [] -> {:error, :not_found}
      _many -> {:error, :ambiguous}
    end
  end

  def account_for_entry(_entry), do: {:error, :not_found}

  @doc """
  The root of every dropped file's staging area: `<tmp>/#{@drop_dir}`.

  Shared by every LiveView session; a single session only ever writes inside
  `session_drop_root/1`.
  """
  def drop_root, do: Path.join(System.tmp_dir!(), @drop_dir)

  @doc """
  The staging root of one LiveView session.

  This is the `:import_root` a confirmed drop is imported with, which is what
  makes its `imported_files` key exactly `"<content_hash>/<basename>"` — a
  content-addressed key the same bytes hit again from any later session.
  """
  def session_drop_root(session_id) when is_binary(session_id),
    do: Path.join(drop_root(), session_id)

  @doc """
  Copies `source_path` into the session staging area and returns its location.

  The layout is `<session root>/<content_hash>/<sanitized basename>`: the
  original basename (and therefore the original extension) is preserved because
  `Ingestor.prepare_content/3` and `Ingestor.statement_meta/2` both switch on
  the file's extension, and because a credit-card statement stamps
  `source_file` with it.

  Returns `{:ok, %{dir:, path:, basename:, content_hash:}}` or
  `{:error, reason}`.
  """
  def stage_drop(session_id, source_path, client_name)
      when is_binary(session_id) and is_binary(source_path) and is_binary(client_name) do
    with {:ok, raw} <- File.read(source_path) do
      hash = content_hash(raw)
      basename = sanitize_basename(client_name)
      dir = Path.join(session_drop_root(session_id), hash)

      with :ok <- File.mkdir_p(dir),
           path = Path.join(dir, basename),
           :ok <- File.write(path, raw) do
        {:ok, %{dir: dir, path: path, basename: basename, content_hash: hash}}
      end
    end
  end

  @doc """
  Removes stale staging directories left by sessions that never ran
  `terminate/2` (a crash, a brutal kill, a VM restart).

  Every session directory other than `keep_session_id` whose mtime is older
  than 24 hours is removed. The age bound is what makes the sweep safe with
  several live tabs: another tab's in-flight staging is always fresh. Failures
  (starting with a root that does not exist yet) are ignored.
  """
  def sweep_stale_drops(keep_session_id) when is_binary(keep_session_id) do
    root = drop_root()

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 == keep_session_id))
        |> Enum.each(&sweep_session(Path.join(root, &1)))

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  @doc """
  The importable accounts that can receive a file of the detected format.

  Eligibility is the **extension family**:
  `extension_of(verdict.format) in Ingestor.expected_extensions(account.parser_type)`.
  The detected `parser_type` never removes an account — it only ranks, since
  the detector can never emit some perfectly valid parser types (no repo OFX
  sample carries the `<ORG>`/`<FID>` tags that would yield `ourocard_ofx`, and
  a PDF without extractable text yields no parser at all). The import always
  runs with the *account's* own `parser_type`.

  Exact `parser_type` matches are listed first, the rest of the family after.
  """
  def candidate_accounts(%{format: format} = verdict) do
    extension = extension_of(format)

    {exact, family} =
      Accounts.list_accounts()
      |> Enum.filter(&importable_for?(&1, extension))
      |> Enum.sort_by(&{&1.bank, &1.name})
      |> Enum.split_with(&exact_parser?(&1, Map.get(verdict, :parser_type)))

    exact ++ family
  end

  @doc """
  The account to pre-select among `candidates`, or `nil`.

  First match wins: a unique candidate, then a unique exact `parser_type`
  match, then a unique case-insensitive `bank` match against the account hint.
  A `nil` hint (or a `nil` `hint.bank`) never matches everything — the rule is
  skipped and nothing is selected.

  Returns `{account, reason}` with `reason` in `:unique | :parser | :bank`, or
  `{nil, nil}`.
  """
  def preselect_account(candidates, verdict)

  def preselect_account([account], _verdict), do: {account, :unique}

  def preselect_account(candidates, verdict) when is_list(candidates) do
    parser_type = Map.get(verdict, :parser_type)
    bank = verdict |> Map.get(:account_hint) |> hint_bank()

    cond do
      match = unique(candidates, &exact_parser?(&1, parser_type)) -> {match, :parser}
      match = unique(candidates, &same_bank?(&1, bank)) -> {match, :bank}
      true -> {nil, nil}
    end
  end

  @doc """
  Detects the format of the file at `path`, extracting PDF text when needed.

  `CashLens.Parsers.FormatDetector` is pure and must not shell out, so the
  two-phase PDF detection lives here: a raw-PDF verdict (`format: :pdf`,
  `parser_type: nil`) is re-submitted to the detector with the text the
  configured converter extracted. A converter failure, blank text, or a second
  verdict still without a parser keeps the first verdict.

  Returns `{:ok, verdict}`, `{:error, :unrecognized}` or `{:error, :unreadable}`.
  """
  def detect_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> detect_content(content, Path.basename(path), path)
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp detect_content(content, basename, path) do
    case FormatDetector.detect(content, filename: basename) do
      {:ok, %{format: :pdf, parser_type: nil} = verdict} ->
        detect_pdf_text(content, basename, path, verdict)

      other ->
        other
    end
  end

  defp detect_pdf_text(content, basename, path, verdict) do
    converter = Application.get_env(:cash_lens, :pdf_converter)

    with {:ok, text} when is_binary(text) <- safe_convert(converter, path),
         false <- String.trim(text) == "",
         {:ok, %{parser_type: parser} = refined} when not is_nil(parser) <-
           FormatDetector.detect(content, filename: basename, text: text) do
      {:ok, refined}
    else
      _ -> {:ok, verdict}
    end
  end

  defp safe_convert(converter, path) do
    converter.convert(path)
  rescue
    _ -> :error
  end

  defp sweep_session(session) do
    case file_mtime(session) do
      nil -> :ok
      mtime -> if DateTime.diff(DateTime.utc_now(), mtime) > @stale_after, do: File.rm_rf(session)
    end
  end

  # A dropped name is never trusted as a path: only its basename survives, and
  # only the characters a filename needs.
  defp sanitize_basename(client_name) do
    case client_name |> Path.basename() |> String.replace(~r/[^\w.\-]/u, "_") do
      "" -> "arquivo"
      "." -> "arquivo"
      ".." -> "arquivo"
      name -> name
    end
  end

  defp importable_for?(account, extension) do
    account.accepts_import and not account.is_closed and
      extension in Ingestor.expected_extensions(account.parser_type)
  end

  defp exact_parser?(_account, nil), do: false
  defp exact_parser?(account, parser_type), do: account.parser_type == parser_type

  defp same_bank?(_account, nil), do: false

  defp same_bank?(account, bank),
    do: is_binary(account.bank) and String.downcase(String.trim(account.bank)) == bank

  defp hint_bank(%{bank: bank}) when is_binary(bank) do
    case bank |> String.trim() |> String.downcase() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp hint_bank(_hint), do: nil

  defp unique(candidates, predicate) do
    case Enum.filter(candidates, predicate) do
      [account] -> account
      _other -> nil
    end
  end

  defp extension_of(:ofx), do: ".ofx"
  defp extension_of(:csv), do: ".csv"
  defp extension_of(:pdf), do: ".pdf"
  defp extension_of(:txt), do: ".txt"
  defp extension_of(_format), do: nil

  defp do_scan(root) do
    expanded_root = Path.expand(root)
    {account_dirs, _skipped} = DirectoryImporter.account_dirs(expanded_root)

    measured = Enum.flat_map(account_dirs, &measure_account_dir(&1, expanded_root))

    recorded =
      measured
      |> Enum.flat_map(&[&1.path, &1.absolute_path])
      |> Enum.uniq()
      |> map_by_paths()

    measured
    |> Enum.map(&classify_entry(&1, recorded))
    |> Enum.sort_by(& &1.path)
  end

  defp measure_account_dir(dir, root) do
    with {:ok, attrs} <- AccountFile.read(dir),
         {:ok, parser_type} <- resolve_parser_type(attrs) do
      {matching, _mismatched} =
        DirectoryImporter.partition_files(dir, Ingestor.expected_extensions(parser_type))

      account_dir = relative_path(dir, root)
      Enum.flat_map(matching, &measure_file(&1, root, account_dir, attrs))
    else
      _ -> []
    end
  end

  # The parser is the one the import would actually use: the registered
  # account's `parser_type`, falling back to the `.account` file's own `parser`
  # when the account does not exist (or is ambiguous) yet.
  defp resolve_parser_type(%{bank: bank, account: name, parser: parser}) do
    case Accounts.find_accounts_by_bank_and_name(bank, name) do
      [account] -> {:ok, account.parser_type}
      _ when is_binary(parser) -> {:ok, parser}
      _ -> :error
    end
  end

  defp measure_file(file, root, account_dir, attrs) do
    with {:ok, raw} <- File.read(file),
         mtime when not is_nil(mtime) <- file_mtime(file) do
      [
        %{
          path: relative_path(file, root),
          absolute_path: Path.expand(file),
          account_dir: account_dir,
          bank: attrs.bank,
          account: attrs.account,
          content_hash: content_hash(raw),
          mtime: mtime
        }
      ]
    else
      _ ->
        Logger.warning("IMPORTS: skipping unreadable file #{file}")
        []
    end
  end

  defp classify_entry(entry, recorded) do
    record = Map.get(recorded, entry.path) || Map.get(recorded, entry.absolute_path)

    {status, last_imported_at} =
      if record do
        {compare_status(record, entry), record.last_imported_at}
      else
        {:new, nil}
      end

    entry
    |> Map.put(:status, status)
    |> Map.put(:last_imported_at, last_imported_at)
  end

  defp compare_status(record, entry) do
    if record.content_hash == entry.content_hash and same_time?(record.mtime, entry.mtime) do
      :synced
    else
      :updated
    end
  end

  defp same_time?(nil, _other), do: false
  defp same_time?(_recorded, nil), do: false
  defp same_time?(recorded, current), do: DateTime.compare(recorded, current) == :eq

  defp normalize_root(root) when is_binary(root) do
    case String.trim(root) do
      "" -> nil
      _trimmed -> root
    end
  end

  defp normalize_root(_root), do: nil
end
