defmodule CashLensWeb.TransactionLive.ImportModalComponent do
  use CashLensWeb, :live_component

  alias CashLens.Accounts
  alias CashLens.Parsers.Ingestor

  @idle_progress %{
    phase: :idle,
    file_index: 0,
    file_total: 0,
    current_file: "",
    current_file_lines: nil,
    lines_done: 0
  }

  @impl true
  def update(%{progress_update: progress}, socket) do
    {:ok, update(socket, :import_progress, &Map.merge(&1, progress))}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:import_progress, fn -> @idle_progress end)
      |> assign_new(:import_accounts, fn ->
        Accounts.list_accounts() |> Enum.filter(& &1.accepts_import)
      end)
      |> assign_new(:import_account_id, fn -> nil end)
      |> allow_upload(:statement,
        accept: ~w(.csv .pdf .ofx),
        max_entries: 100,
        max_file_size: 10_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_import", %{"account_id" => account_id}, socket) do
    {:noreply, assign(socket, :import_account_id, account_id)}
  end

  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    account = Accounts.get_account!(account_id)

    case consume_uploaded_entries(socket, :statement, &copy_to_temp/2) do
      [] ->
        send(self(), {:import_error, "Nenhum arquivo selecionado."})
        {:noreply, socket}

      file_paths ->
        total = length(file_paths)

        socket =
          assign(socket, :import_progress, %{
            phase: :importing,
            file_index: 0,
            file_total: total,
            current_file: "",
            current_file_lines: nil,
            lines_done: 0
          })

        start_bulk_import(account, {:files, file_paths})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_import_modal)
    {:noreply, assign(socket, :import_progress, @idle_progress)}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :statement, ref)}
  end

  defp copy_to_temp(%{path: path}, entry) do
    filename = Path.basename(entry.client_name)
    dest = Path.join(System.tmp_dir!(), "#{entry.uuid}-#{filename}")
    File.cp!(path, dest)
    {:ok, dest}
  end

  defp start_bulk_import(account, {:files, file_paths}) do
    pid = self()
    total = length(file_paths)

    process_import = fn ->
      {results, _lines_acc} =
        file_paths
        |> Enum.with_index(1)
        |> Enum.reduce({[], 0}, fn {path, index}, {results, lines_acc} ->
          filename = Path.basename(path)
          send(pid, {:import_file_start, index, total, filename})

          res =
            Ingestor.import_file(account, path, notify_fn: &send(pid, {:import_file_parsed, &1}))

          File.rm(path)

          new_lines_acc =
            case res do
              {:ok, %{imported: n}} ->
                cumulative = lines_acc + n
                send(pid, {:import_file_done, cumulative})
                cumulative

              _ ->
                lines_acc
            end

          {results ++ [res], new_lines_acc}
        end)

      case summarize_import_results(results) do
        {:ok, summary} -> send(pid, {:import_success, summary})
        {:error, reason} -> send(pid, {:import_error, reason})
      end
    end

    if Application.get_env(:cash_lens, :sql_sandbox) do
      process_import.()
    else
      task_start = Application.get_env(:cash_lens, :task_start_fn, &Task.start/1)
      task_start.(process_import)
    end
  end

  defp summarize_import_results(results) do
    {successes, file_errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    total_imported = successes |> Enum.map(fn {:ok, %{imported: n}} -> n end) |> Enum.sum()
    all_failed = successes |> Enum.flat_map(fn {:ok, %{failed: f}} -> f end)

    if Enum.empty?(file_errors) do
      {:ok, %{imported: total_imported, failed: all_failed}}
    else
      {:error,
       "#{length(file_errors)} arquivo(s) com falha. Total de transações dos arquivos bem-sucedidos: #{total_imported}"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal :if={@show} id="import-modal" show on_cancel={JS.push("close", target: @myself)}>
        <div class="p-2">
          <%= if @import_progress.phase == :importing do %>
            <.progress_view progress={@import_progress} />
          <% else %>
            <.import_form
              myself={@myself}
              import_accounts={@import_accounts}
              import_account_id={@import_account_id}
              uploads={@uploads}
            />
          <% end %>
        </div>
      </.modal>
    </div>
    """
  end

  defp progress_view(assigns) do
    ~H"""
    <div class="py-2 space-y-6 min-h-[200px]">
      <h2 class="text-2xl font-black uppercase tracking-tighter text-primary">
        Importando...
      </h2>

      <div>
        <p class="text-[10px] font-black uppercase opacity-40 mb-2">Arquivo Atual</p>
        <div class="flex items-center gap-2">
          <.icon name="hero-document-text" class="size-4 text-primary shrink-0" />
          <span class="text-sm font-bold truncate">{@progress.current_file}</span>
        </div>
      </div>

      <div :if={@progress.file_total > 1}>
        <div class="flex justify-between items-center mb-2">
          <span class="text-[10px] font-black uppercase opacity-40">Arquivos</span>
          <span class="text-[10px] font-black opacity-60 tabular-nums">
            {@progress.file_index} / {@progress.file_total}
          </span>
        </div>
        <progress
          class="progress progress-primary w-full"
          value={@progress.file_index}
          max={@progress.file_total}
        />
      </div>

      <div>
        <div class="flex justify-between items-center mb-2">
          <span class="text-[10px] font-black uppercase opacity-40">Transações</span>
          <span class="text-[10px] font-black opacity-60 tabular-nums">
            {cond do
              @progress.current_file_lines == :parsing ->
                "#{@progress.lines_done} + lendo..."

              is_integer(@progress.current_file_lines) ->
                "#{@progress.lines_done + @progress.current_file_lines} encontradas"

              true ->
                "#{@progress.lines_done} importadas"
            end}
          </span>
        </div>
        <%= if @progress.current_file_lines == :parsing do %>
          <progress class="progress progress-primary w-full" />
        <% else %>
          <progress
            class="progress progress-primary w-full"
            value={@progress.lines_done}
            max={max(@progress.lines_done, 1)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp import_form(assigns) do
    ~H"""
    <div>
      <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">
        Importar Extratos
      </h2>

      <form
        id="upload-form"
        phx-target={@myself}
        phx-submit="save_import"
        phx-change="validate_import"
      >
        <div class="form-control w-full mb-8">
          <label class="label">
            <span class="label-text font-black uppercase opacity-40 text-[10px]">
              1. Selecione a Conta de Destino
            </span>
          </label>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-2">
            <%= for account <- @import_accounts do %>
              <label class={[
                "flex items-center gap-3 p-3 border-2 rounded-2xl cursor-pointer hover:bg-base-200 transition-all group",
                if(@import_account_id == account.id,
                  do: "border-primary bg-primary/5",
                  else: "border-base-300"
                )
              ]}>
                <input
                  type="radio"
                  name="account_id"
                  value={account.id}
                  class="radio radio-primary radio-sm"
                  required
                  checked={@import_account_id == account.id}
                />

                <div class="avatar">
                  <div class="w-8 rounded-full bg-base-300 overflow-hidden">
                    <%= if account.icon && account.icon != "" do %>
                      <img src={account.icon} />
                    <% else %>
                      <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content text-[10px] font-bold">
                        {String.slice(account.bank || account.name, 0..1)}
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="min-w-0">
                  <span class="block font-bold text-sm truncate">{account.name}</span>
                  <span class="block text-[9px] opacity-50 uppercase font-black">
                    {account.parser_type || "N/A"}
                  </span>
                </div>
              </label>
            <% end %>

            <.link
              navigate={~p"/accounts/new?return_to=transactions"}
              class="flex items-center gap-3 p-3 border-2 border-dashed border-base-300 rounded-2xl cursor-pointer hover:border-primary hover:bg-primary/5 transition-all group"
            >
              <div class="avatar">
                <div class="w-8 rounded-full bg-base-200 flex items-center justify-center">
                  <.icon
                    name="hero-plus"
                    class="size-4 opacity-40 group-hover:text-primary group-hover:opacity-100"
                  />
                </div>
              </div>
              <div class="min-w-0">
                <span class="block font-bold text-sm opacity-60 group-hover:text-primary">
                  Adicionar Conta
                </span>
              </div>
            </.link>
          </div>
        </div>

        <div class="form-control w-full mb-8">
          <label class="label">
            <span class="label-text font-black uppercase opacity-40 text-[10px]">
              2. Selecione o Arquivo
            </span>
          </label>

          <div class="p-10 border-2 border-dashed border-base-300 rounded-3xl bg-base-200/50 flex flex-col items-center justify-center group hover:border-primary transition-all cursor-pointer relative">
            <.live_file_input
              upload={@uploads.statement}
              class="absolute inset-0 opacity-0 cursor-pointer w-full h-full"
            />
            <.icon
              name="hero-cloud-arrow-up"
              class="size-12 opacity-20 mb-4 group-hover:text-primary group-hover:opacity-100 transition-all"
            />
            <p class="text-sm font-medium opacity-40 text-center">
              Arraste os arquivos ou clique para selecionar
            </p>
          </div>

          <div
            :if={!Enum.empty?(@uploads.statement.entries)}
            class="mt-4 max-h-40 overflow-y-auto space-y-2 p-1"
          >
            <div
              :for={entry <- @uploads.statement.entries}
              class="p-2 bg-base-100 rounded-lg border border-base-300 flex items-center justify-between animate-in fade-in zoom-in-95"
            >
              <div class="flex items-center gap-2 min-w-0">
                <.icon name="hero-document-text" class="size-4 text-primary shrink-0" />
                <span class="text-[10px] font-bold truncate">{entry.client_name}</span>
              </div>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </div>
          </div>
        </div>

        <button
          type="submit"
          class="btn btn-primary btn-lg w-full rounded-2xl shadow-lg shadow-primary/20"
          phx-disable-with="Processando..."
          disabled={Enum.empty?(@uploads.statement.entries)}
        >
          Iniciar Importação
        </button>
      </form>
    </div>
    """
  end
end
