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

  @statuses [:new, :updated, :synced]

  @badges %{
    new: %{label: "Novo", class: "bg-emerald-50 text-emerald-700 border-emerald-200"},
    updated: %{label: "Atualizado", class: "bg-amber-50 text-amber-700 border-amber-200"},
    synced: %{label: "Sincronizado", class: "bg-slate-100 text-slate-500 border-slate-200"}
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
              <td>
                <!-- CL-24: pre-write inspection action per row -->
              </td>
            </tr>
          </tbody>
        </table>
      </section>
      <!-- CL-26: recent import history -->
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
     |> assign_scan(root)}
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
  def handle_event("rescan", _params, socket) do
    {:noreply,
     socket
     |> assign_scan(socket.assigns.root)
     |> put_flash(:info, "Pasta reescaneada.")}
  end

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

  defp format_datetime(nil), do: "—"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
end
