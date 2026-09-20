defmodule CashLensWeb.ImportLive.Index do
  @moduledoc """
  The import hub shell (CL-23): the monitored-folder card and the file list
  coloured by the status `CashLens.Imports.scan/1` computes.

  This screen only reads the filesystem — it never imports anything. The
  monitored root is read through `CashLens.Imports.import_root/1` and written
  through `CashLens.Imports.put_import_root/1`, so the settings key backing it
  never leaks into the web layer and the scanned folder can never disagree
  with the key used for `imported_files` rows.
  """
  use CashLensWeb, :live_view

  alias CashLens.Imports
  alias CashLens.Parsers.Ingestor

  @statuses [:new, :updated, :synced]

  # The drawer renders at most this many preview rows. The Ingestor always
  # returns every row: truncating there would make the same function mean
  # different things to different callers, and the two counters above the table
  # are always the Ingestor's full-file numbers, never derived from this slice.
  @preview_limit 200

  # The history is a recency panel, not a log browser: it shows the newest runs
  # up to this bound and offers no pagination.
  @history_limit 20

  # A `file_path` directory that is a bare SHA-256 is a dropped file's key: it
  # is meaningless to the operator, so it is labelled instead of shown.
  @content_hash_dir ~r/^[0-9a-f]{64}$/

  @badges %{
    new: %{label: "Novo", class: "bg-emerald-50 text-emerald-700 border-emerald-200"},
    updated: %{label: "Atualizado", class: "bg-amber-50 text-amber-700 border-amber-200"},
    synced: %{label: "Sincronizado", class: "bg-slate-100 text-slate-500 border-slate-200"}
  }

  @run_badges %{
    "success" => %{label: "Sucesso", class: "bg-emerald-50 text-emerald-700 border-emerald-200"},
    "warning" => %{label: "Aviso", class: "bg-amber-50 text-amber-700 border-amber-200"},
    "error" => %{label: "Erro", class: "bg-red-50 text-red-700 border-red-200"}
  }

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6">
      <.header>
        Central de Importação
        <:subtitle>
          Acompanhe a pasta de extratos sincronizada e veja o que ainda não foi ingerido.
        </:subtitle>
      </.header>

      <section class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body p-5 gap-3">
          <form
            id="import-root-form"
            phx-submit="save_path"
            phx-change="validate_path"
            class="flex flex-col lg:flex-row lg:items-end gap-4"
          >
            <div class="flex-1 min-w-0">
              <label for="import-root-input" class="text-[10px] font-black uppercase opacity-50">
                Pasta monitorada
              </label>
              <input
                id="import-root-input"
                type="text"
                name="path"
                value={@path_input}
                autocomplete="off"
                class="input input-bordered w-full font-mono text-xs mt-1.5"
              />
              <p :if={@using_default?} class="mt-2 text-[11px] font-semibold text-amber-600">
                Caminho padrão em uso — salve para que os arquivos sejam registrados de forma
                relativa à pasta.
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button type="submit" class="btn btn-primary rounded-xl" phx-disable-with="Salvando...">
                <.icon name="hero-check" class="size-4" /> Salvar
              </button>
              <button id="rescan-button" type="button" phx-click="rescan" class="btn rounded-xl">
                <.icon name="hero-arrow-path" class="size-4" /> Reescanear
              </button>
            </div>
          </form>
          <p class="text-[11px] opacity-50">
            Somente pastas marcadas com um arquivo <code class="font-mono">.account</code>
            são listadas.
          </p>
        </div>
      </section>
      <!-- CL-25: universal dropzone -->

      <section :if={@scan_error} id="scan-error" class="alert alert-warning items-start rounded-2xl">
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <div>
          <p class="font-bold">Pasta não encontrada</p>
          <p class="text-xs font-mono break-all">{@root}</p>
          <p class="text-xs">
            O caminho não existe ou não é uma pasta. Se ela vive no Google Drive, verifique se o
            drive está montado e reescaneie.
          </p>
        </div>
      </section>

      <section
        :if={is_nil(@scan_error) and @entries == []}
        id="scan-empty"
        class="card bg-base-100 shadow-sm border border-base-300 p-10 text-center"
      >
        <p class="text-sm font-bold opacity-60">Nenhum arquivo encontrado</p>
        <p class="text-xs opacity-40 mt-1">
          A pasta existe, mas não há subpastas marcadas com <code class="font-mono">.account</code>
          contendo extratos compatíveis.
        </p>
      </section>

      <section
        :if={is_nil(@scan_error) and @entries != []}
        id="file-list"
        class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden"
      >
        <div class="px-5 py-4 border-b border-base-300 flex items-center justify-between gap-3">
          <h2 class="text-sm font-black uppercase opacity-50">Arquivos</h2>
          <div class="text-[11px] font-bold opacity-60">{@counters}</div>
        </div>
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Arquivo</th>
              <th>Conta</th>
              <th>Situação</th>
              <th>Detalhes</th>
              <th class="w-10"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={entry <- @entries}
              data-path={entry.path}
              data-status={entry.status}
              class="hover"
            >
              <td class="font-mono font-bold break-all">{entry.path}</td>
              <td class="opacity-60">{entry.bank} · {entry.account}</td>
              <td>
                <span class={[
                  "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border",
                  "text-[11px] font-black",
                  badge(entry.status).class
                ]}>
                  {badge(entry.status).label}
                </span>
              </td>
              <td class="opacity-60">
                <span
                  :if={entry.status == :updated}
                  class="font-mono text-amber-700"
                  title={entry.content_hash}
                >{short_hash(entry.content_hash)}… ·
                </span>{details(entry)}
              </td>
              <td class="text-right">
                <button
                  type="button"
                  data-role="inspect"
                  phx-click="inspect"
                  phx-value-path={entry.path}
                  class="btn btn-xs rounded-lg gap-1.5"
                >
                  <.icon name="hero-eye" class="size-3.5" /> Inspecionar
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
      <section
        id="import-history"
        class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden"
      >
        <div class="px-5 py-4 border-b border-base-300">
          <h2 class="text-sm font-black uppercase opacity-50">Importações recentes</h2>
          <p class="text-[11px] font-bold opacity-40 mt-0.5">
            Últimas {@history_limit} execuções
          </p>
        </div>

        <table :if={@history != []} class="table w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th class="w-36">Data</th>
              <th>Conta</th>
              <th>Arquivo</th>
              <th class="w-44">Situação</th>
              <th class="text-right w-28">Importadas</th>
              <th class="text-right w-28">Ignoradas</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={run <- @history}
              data-run-id={run.id}
              data-run-status={run.status}
              class="hover"
            >
              <td class="align-top whitespace-nowrap font-semibold">
                {format_datetime(run.ran_at)}
              </td>
              <td class="align-top">
                <span :if={run.account} class="font-semibold">
                  {run_account_label(run.account)}
                </span>
                <span :if={is_nil(run.account)} class="opacity-40" title="Conta removida">—</span>
              </td>
              <td class="align-top" title={run.file_path}>
                <p class="font-mono text-[11px] font-bold break-all">
                  {run_file_label(run.file_path).base}
                </p>
                <p
                  :if={run_file_label(run.file_path).subtitle}
                  class="text-[11px] opacity-40 truncate max-w-xs"
                >
                  {run_file_label(run.file_path).subtitle}
                </p>
                <p
                  :if={run.error_message}
                  data-role="run-error"
                  class="mt-1 text-[11px] font-semibold text-red-600"
                >
                  {run.error_message}
                </p>
              </td>
              <td class="align-top">
                <span class={[
                  "inline-block border px-2 py-0.5 rounded-full",
                  "text-[10px] font-black uppercase",
                  run_badge(run.status).class
                ]}>
                  {run_badge(run.status).label}
                </span>
                <p
                  :if={run.status == "warning" and run.failed_count > 0}
                  data-role="run-failed"
                  class="mt-1 text-[10px] font-bold text-amber-600"
                >
                  {run.failed_count} linha(s) rejeitada(s)
                </p>
              </td>
              <td class={[
                "align-top text-right font-bold",
                run.imported_count == 0 && "opacity-30"
              ]}>
                {run.imported_count}
              </td>
              <td class={[
                "align-top text-right font-bold",
                run.skipped_count == 0 && "opacity-30"
              ]}>
                {run.skipped_count}
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={@history == []} id="history-empty" class="px-5 py-12 text-center">
          <p class="text-sm font-bold opacity-60">Nenhuma importação registrada ainda.</p>
          <p class="text-[11px] opacity-40 mt-1">
            O histórico registra apenas importações executadas — uma inspeção pré-gravação
            não escreve nada.
          </p>
        </div>
      </section>

      <.modal :if={@inspect} id="inspect-drawer" show on_cancel={JS.push("close_inspect")}>
        <div class="space-y-4">
          <div class="min-w-0">
            <p class="text-[10px] font-black uppercase tracking-wider text-primary">
              Inspeção pré-gravação
            </p>
            <p id="inspect-path" class="mt-1 font-mono text-sm font-bold break-all">
              {@inspect.entry.path}
            </p>
            <p id="inspect-account" class="text-xs opacity-50 mt-0.5">
              {@inspect.entry.bank} · {@inspect.entry.account}
            </p>
          </div>

          <div class="alert alert-info rounded-2xl text-[11px] font-bold items-start">
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            <span>
              Simulação — nenhuma transação, arquivo importado ou execução foi gravada até aqui.
            </span>
          </div>

          <div
            :if={@inspect.error}
            id="inspect-error"
            class="alert alert-warning rounded-2xl items-start"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
            <div>
              <p class="text-sm font-bold">Não foi possível montar a prévia</p>
              <p id="inspect-error-detail" class="text-xs mt-1">{@inspect.error}</p>
            </div>
          </div>

          <div :if={@inspect.summary} class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div class="rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3">
                <p class="text-[10px] font-black uppercase tracking-wider text-emerald-600">
                  Novas transações
                </p>
                <p id="preview-new-count" class="text-3xl font-black text-emerald-700 mt-0.5">
                  {@inspect.summary.imported}
                </p>
              </div>
              <div class="rounded-2xl border border-base-300 bg-base-200/50 px-4 py-3">
                <p class="text-[10px] font-black uppercase tracking-wider opacity-40">
                  Duplicadas ignoradas
                </p>
                <p id="preview-skipped-count" class="text-3xl font-black opacity-60 mt-0.5">
                  {@inspect.summary.skipped}
                </p>
              </div>
            </div>

            <p
              :if={@inspect.summary.imported == 0}
              id="preview-nothing"
              class="text-xs font-bold opacity-60 bg-base-200/50 border border-base-300 rounded-xl px-4 py-3"
            >
              Nada novo para importar — o arquivo já está integralmente no banco.
            </p>

            <div
              :if={@inspect.summary.failed != []}
              id="preview-failed"
              class="alert alert-warning rounded-2xl items-start text-xs"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              <div>
                <p class="font-bold">{length(@inspect.summary.failed)} linhas rejeitadas</p>
                <ul class="mt-1 space-y-0.5 font-mono break-all">
                  <li :for={{description, reason} <- Enum.take(@inspect.summary.failed, 10)}>
                    {description} — {reason}
                  </li>
                </ul>
              </div>
            </div>

            <div class="max-h-80 overflow-y-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th class="w-24">Data</th>
                    <th>Descrição</th>
                    <th class="text-right w-28">Valor</th>
                    <th class="text-right w-28">Situação</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- Enum.take(@inspect.summary.preview, @preview_limit)}
                    data-preview-row
                    data-row-status={row.status}
                    class={row.status == :duplicate && "opacity-40"}
                  >
                    <td class="font-mono">{format_date(row.date)}</td>
                    <td class="font-semibold break-all">{row.description}</td>
                    <td class="text-right font-mono">{format_currency(row.amount)}</td>
                    <td class="text-right">
                      <span class={[
                        "px-2 py-0.5 rounded-md border text-[10px] font-black",
                        row_badge_class(row.status)
                      ]}>
                        {row_badge_label(row.status)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p
              :if={length(@inspect.summary.preview) > @preview_limit}
              id="preview-truncated"
              class="text-[11px] font-bold opacity-40 text-center"
            >
              mostrando {@preview_limit} de {length(@inspect.summary.preview)} linhas — os totais
              acima são do arquivo inteiro
            </p>
          </div>

          <div class="flex items-center justify-between gap-3 border-t border-base-300 pt-4">
            <p class="text-[11px] opacity-40">
              Confirmar grava as transações novas e registra a execução no histórico.
            </p>
            <div class="flex items-center gap-2">
              <button
                id="inspect-cancel"
                type="button"
                phx-click="close_inspect"
                class="btn btn-sm rounded-xl"
              >
                Cancelar
              </button>
              <button
                :if={@inspect.summary}
                id="confirm-import"
                type="button"
                phx-click="confirm_import"
                phx-disable-with="Importando..."
                class="btn btn-sm btn-primary rounded-xl gap-1.5"
              >
                <.icon name="hero-check" class="size-4" /> Confirmar importação
              </button>
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    stored_root = Imports.import_root([])
    root = stored_root || Imports.default_import_root()

    {:ok,
     socket
     |> assign(:page_title, "Central de Importação")
     |> assign(:using_default?, is_nil(stored_root))
     |> assign(:preview_limit, @preview_limit)
     |> assign(:inspect, nil)
     |> assign(:history_limit, @history_limit)
     |> assign_scan(root)
     |> assign_history()}
  end

  @impl true
  def handle_event("validate_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, :path_input, path)}
  end

  @impl true
  def handle_event("save_path", %{"path" => path}, socket) do
    case Imports.put_import_root(path) do
      {:ok, saved} ->
        socket = socket |> assign(:using_default?, false) |> assign_scan(saved)
        {:noreply, put_flash(socket, :info, saved_message(socket))}

      :error ->
        {:noreply,
         socket
         |> assign(:path_input, socket.assigns.root)
         |> put_flash(:error, "Informe um caminho.")}
    end
  end

  @impl true
  def handle_event("inspect", %{"path" => path}, socket) do
    case find_entry(socket, path) do
      nil -> {:noreply, socket}
      entry -> {:noreply, assign(socket, :inspect, build_inspection(entry))}
    end
  end

  @impl true
  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, :inspect, nil)}
  end

  @impl true
  def handle_event("confirm_import", _params, %{assigns: %{inspect: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_import", _params, socket) do
    inspection = socket.assigns.inspect

    if inspection.summary do
      confirm_import(socket, inspection)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    {:noreply,
     socket
     |> assign_scan(socket.assigns.root)
     |> assign_history()
     |> put_flash(:info, "Pasta reescaneada.")}
  end

  # The path coming from the client is never used as a filesystem path: it is
  # looked up against the last scan, and the absolute path actually read is
  # always the scanned `:absolute_path`.
  defp find_entry(socket, path), do: Enum.find(socket.assigns.entries, &(&1.path == path))

  # Builds the inspection state for one entry. This is a strictly read-only
  # path: account resolution is a SELECT and the Ingestor runs with
  # `dry_run: true`, which writes no transaction, no `imported_files` row, no
  # `import_runs` row and no credit-card statement.
  defp build_inspection(entry) do
    base = %{entry: entry, account: nil, summary: nil, hash: entry.content_hash, error: nil}

    case Imports.account_for_entry(entry) do
      {:ok, account} -> %{base | account: account} |> run_preview()
      {:error, :not_found} -> %{base | error: account_error(:not_found, entry)}
      {:error, :ambiguous} -> %{base | error: account_error(:ambiguous, entry)}
    end
  end

  defp run_preview(%{entry: entry, account: account} = inspection) do
    case Ingestor.import_file(account, entry.absolute_path, dry_run: true) do
      {:ok, summary} -> %{inspection | summary: summary, error: nil}
      {:error, reason} -> %{inspection | summary: nil, error: to_string(reason)}
    end
  end

  defp account_error(:not_found, entry),
    do: "Conta não encontrada para esta pasta: #{entry.bank} · #{entry.account}."

  defp account_error(:ambiguous, entry),
    do: "A conta #{entry.bank} · #{entry.account} está ambígua: mais de um cadastro corresponde."

  # The confirm path re-reads the file and compares its hash against the bytes
  # the operator inspected. The check narrows the window but is not atomic —
  # `Ingestor.import_file/3` performs its own `File.read/1` — which is accepted
  # for a local single-operator folder and documented in the CL-24 spec.
  defp confirm_import(socket, %{entry: entry, account: account} = inspection) do
    case File.read(entry.absolute_path) do
      {:ok, raw} ->
        if Imports.content_hash(raw) == inspection.hash do
          run_real_import(socket, entry, account)
        else
          refresh_stale_preview(socket, entry)
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Não foi possível ler o arquivo: #{reason}")}
    end
  end

  defp run_real_import(socket, entry, account) do
    root = socket.assigns.root

    case Ingestor.import_file(account, entry.absolute_path, import_root: root) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> assign(:inspect, nil)
         |> assign_scan(root)
         |> assign_history()
         |> put_flash(:info, imported_message(summary))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao importar: #{reason}")}
    end
  end

  # The file changed between opening the drawer and confirming: nothing is
  # imported and the drawer immediately shows the preview of the new bytes, so
  # the operator never confirms something they did not see.
  defp refresh_stale_preview(socket, entry) do
    refreshed =
      case Imports.scan(socket.assigns.root) do
        {:ok, entries} -> Enum.find(entries, &(&1.path == entry.path)) || entry
        {:error, _reason} -> entry
      end

    {:noreply,
     socket
     |> assign(:inspect, build_inspection(refreshed))
     |> put_flash(:error, "O arquivo mudou no disco. Inspecione novamente.")}
  end

  defp imported_message(summary) do
    "#{summary.imported} transações importadas, #{Map.get(summary, :skipped, 0)} duplicadas ignoradas."
  end

  defp row_badge_label(:new), do: "Nova"
  defp row_badge_label(:duplicate), do: "Duplicada"

  defp row_badge_class(:new), do: "bg-emerald-50 text-emerald-700 border-emerald-200"
  defp row_badge_class(:duplicate), do: "bg-base-200 opacity-60 border-base-300"

  # The single scanning path: `mount/3` and `"rescan"` both go through it so
  # the two can never drift.
  defp assign_scan(socket, root) do
    {entries, error} =
      case Imports.scan(root) do
        {:ok, entries} -> {entries, nil}
        {:error, reason} -> {[], reason}
      end

    socket
    |> assign(:root, root)
    |> assign(:path_input, root)
    |> assign(:entries, entries)
    |> assign(:scan_error, error)
    |> assign(:counters, counters(entries))
  end

  defp saved_message(%{assigns: %{scan_error: nil}}), do: "Pasta monitorada salva."
  defp saved_message(_socket), do: "Caminho salvo, mas a pasta não foi encontrada."

  defp badge(status), do: Map.fetch!(@badges, status)

  defp counters(entries) do
    Enum.map_join(@statuses, " · ", fn status ->
      count = Enum.count(entries, &(&1.status == status))
      "#{count} #{counter_label(status, count)}"
    end)
  end

  defp counter_label(:new, 1), do: "novo"
  defp counter_label(:new, _count), do: "novos"
  defp counter_label(:updated, 1), do: "atualizado"
  defp counter_label(:updated, _count), do: "atualizados"
  defp counter_label(:synced, 1), do: "sincronizado"
  defp counter_label(:synced, _count), do: "sincronizados"

  # `scan/1` never returns the recorded hash, only the current disk one, so an
  # `:updated` row states what is on disk now versus when it was last imported
  # and never invents a "previous hash".
  defp details(%{status: :updated} = entry) do
    "modificado em #{format_datetime(entry.mtime)}" <>
      " · importado em #{format_datetime(entry.last_imported_at)}"
  end

  defp details(%{status: :synced} = entry),
    do: "importado em #{format_datetime(entry.last_imported_at)}"

  defp details(entry), do: "modificado em #{format_datetime(entry.mtime)}"

  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 8)
  defp short_hash(_hash), do: ""

  # The single history path: `mount/3`, `"rescan"` and a confirmed import all go
  # through it, so a confirmed import's row appears without a page reload.
  defp assign_history(socket) do
    assign(socket, :history, Imports.list_recent_runs(@history_limit))
  end

  # Total over any string the column can physically hold: a value written around
  # the changeset renders grey and raw instead of crashing the screen.
  defp run_badge(status) do
    Map.get(@run_badges, status, %{
      label: status,
      class: "bg-slate-100 text-slate-600 border-slate-200"
    })
  end

  defp run_account_label(nil), do: nil
  defp run_account_label(account), do: account_label(account)

  # `file_path` is the denormalized path *key*, not a filesystem path: the
  # basename leads and the directory becomes a subtitle, decoded when it is a
  # content hash. The cell's `title` keeps the full stored value.
  defp run_file_label(file_path) do
    %{base: Path.basename(file_path), subtitle: run_file_subtitle(Path.dirname(file_path))}
  end

  defp run_file_subtitle("."), do: nil

  defp run_file_subtitle(dir) do
    if Regex.match?(@content_hash_dir, dir) do
      "Arquivo solto · #{String.slice(dir, 0, 8)}…"
    else
      dir
    end
  end

  defp format_datetime(nil), do: "—"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
end
