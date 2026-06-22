defmodule CashLensWeb.TransactionLive.BatchImportModalComponent do
  use CashLensWeb, :live_component

  alias CashLens.Parsers.DirectoryImporter

  @idle_progress %{
    phase: :idle,
    total_accounts: 0,
    accounts_done: 0,
    current_account: nil,
    current_account_file_index: 0,
    current_account_file_total: 0,
    result: nil
  }

  @impl true
  def update(%{progress_update: progress}, socket) do
    {:ok, update(socket, :batch_progress, &Map.merge(&1, progress))}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:batch_progress, fn -> @idle_progress end)
      |> assign_new(:batch_path, fn -> CashLens.Settings.get("last_batch_import_path", "") end)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, :batch_path, path)}
  end

  @impl true
  def handle_event("start_batch_import", %{"path" => path}, socket) do
    path = String.trim(path)
    CashLens.Settings.put("last_batch_import_path", path)

    socket =
      socket
      |> assign(:batch_path, path)
      |> assign(:batch_progress, %{@idle_progress | phase: :importing})

    start_batch_import(path)
    {:noreply, socket}
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_batch_import_modal)
    {:noreply, assign(socket, :batch_progress, @idle_progress)}
  end

  defp start_batch_import(path) do
    pid = self()

    process_import = fn ->
      {:ok, agent} =
        Agent.start_link(fn ->
          %{total_accounts: 0, accounts_done: 0, current_file_index: 0}
        end)

      try do
        result = DirectoryImporter.run(path, on_event: build_on_event(pid, agent))
        send(pid, {:batch_import_finished, result})
      rescue
        # coveralls-ignore-start — defensive guard so a crash inside the import Task
        # surfaces to the UI instead of dying silently; not deterministically testable.
        e ->
          error_result = %DirectoryImporter.Result{
            errors: ["Erro inesperado: #{Exception.message(e)}"]
          }

          send(pid, {:batch_import_finished, error_result})
          # coveralls-ignore-stop
      after
        Agent.stop(agent)
      end
    end

    if Application.get_env(:cash_lens, :sql_sandbox) do
      process_import.()
    else
      task_start = Application.get_env(:cash_lens, :task_start_fn, &Task.start/1)
      task_start.(process_import)
    end
  end

  # Mirrors the two-level progress (accounts + files per account) that
  # `mix cash_lens.import` renders in the terminal via Owl progress bars.
  defp build_on_event(pid, agent) do
    fn
      {:start, total} ->
        Agent.update(agent, &Map.put(&1, :total_accounts, total))
        send(pid, {:batch_import_progress, %{total_accounts: total}})

      {:account_start, label, file_total} ->
        Agent.update(agent, &Map.put(&1, :current_file_index, 0))

        send(
          pid,
          {:batch_import_progress,
           %{
             current_account: label,
             current_account_file_index: 0,
             current_account_file_total: file_total
           }}
        )

      {:file_done, _label} ->
        idx =
          Agent.get_and_update(agent, fn s ->
            idx = s.current_file_index + 1
            {idx, %{s | current_file_index: idx}}
          end)

        send(pid, {:batch_import_progress, %{current_account_file_index: idx}})

      {:account_done, _summary} ->
        done =
          Agent.get_and_update(agent, fn s ->
            done = s.accounts_done + 1
            {done, %{s | accounts_done: done}}
          end)

        send(pid, {:batch_import_progress, %{accounts_done: done}})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal :if={@show} id="batch-import-modal" show on_cancel={JS.push("close", target: @myself)}>
        <div class="p-2">
          <%= case @batch_progress.phase do %>
            <% :importing -> %>
              <.progress_view progress={@batch_progress} />
            <% :done -> %>
              <.result_view result={@batch_progress.result} myself={@myself} />
            <% _ -> %>
              <.path_form myself={@myself} batch_path={@batch_path} />
          <% end %>
        </div>
      </.modal>
    </div>
    """
  end

  defp path_form(assigns) do
    ~H"""
    <div>
      <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
        Importar em Lote
      </h2>
      <p class="text-sm opacity-60 mb-6">
        Informe o caminho de uma pasta no servidor. Cada subpasta com um arquivo
        <code class="text-xs bg-base-200 px-1 py-0.5 rounded">.account</code>
        será importada para a conta correspondente.
      </p>

      <form
        id="batch-import-form"
        phx-target={@myself}
        phx-submit="start_batch_import"
        phx-change="validate_path"
      >
        <div class="form-control w-full mb-8">
          <label class="label">
            <span class="label-text font-black uppercase opacity-40 text-[10px]">
              Caminho da Pasta
            </span>
          </label>
          <input
            type="text"
            name="path"
            value={@batch_path}
            placeholder="/caminho/para/extratos"
            class="input input-bordered w-full"
            required
            autocomplete="off"
          />
        </div>

        <button
          type="submit"
          class="btn btn-primary btn-lg w-full rounded-2xl shadow-lg shadow-primary/20"
          phx-disable-with="Processando..."
          disabled={@batch_path == ""}
        >
          Iniciar Importação em Lote
        </button>
      </form>
    </div>
    """
  end

  defp progress_view(assigns) do
    ~H"""
    <div class="py-2 space-y-6 min-h-[200px]">
      <h2 class="text-2xl font-black uppercase tracking-tighter text-primary">
        Importando em Lote...
      </h2>

      <div>
        <div class="flex justify-between items-center mb-2">
          <span class="text-[10px] font-black uppercase opacity-40">Contas</span>
          <span class="text-[10px] font-black opacity-60 tabular-nums">
            {@progress.accounts_done} / {@progress.total_accounts}
          </span>
        </div>
        <progress
          class="progress progress-primary w-full"
          value={@progress.accounts_done}
          max={max(@progress.total_accounts, 1)}
        />
      </div>

      <div :if={@progress.current_account}>
        <p class="text-[10px] font-black uppercase opacity-40 mb-2">Conta Atual</p>
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-folder-open" class="size-4 text-primary shrink-0" />
          <span class="text-sm font-bold truncate">{@progress.current_account}</span>
        </div>

        <div class="flex justify-between items-center mb-2">
          <span class="text-[10px] font-black uppercase opacity-40">Arquivos</span>
          <span class="text-[10px] font-black opacity-60 tabular-nums">
            {@progress.current_account_file_index} / {@progress.current_account_file_total}
          </span>
        </div>
        <progress
          class="progress progress-secondary w-full"
          value={@progress.current_account_file_index}
          max={max(@progress.current_account_file_total, 1)}
        />
      </div>
    </div>
    """
  end

  defp result_view(assigns) do
    ~H"""
    <div class="py-2 space-y-6">
      <h2 class="text-2xl font-black uppercase tracking-tighter text-primary">
        Importação Concluída
      </h2>

      <div class="max-h-80 overflow-y-auto space-y-2">
        <div
          :for={account <- @result.accounts}
          class="p-3 bg-base-200/50 rounded-xl border border-base-300"
        >
          <div class="flex items-center gap-2">
            <.icon name="hero-check-circle" class="size-4 text-success shrink-0" />
            <span class="text-sm font-bold truncate">{account.folder_path}</span>
          </div>
          <p class="text-xs opacity-60 ml-6">
            {account.imported} importadas
            <%= if account.skipped > 0 do %>
              , {account.skipped} já existiam
            <% end %>
            <%= if account.failed != [] do %>
              , {length(account.failed)} com falha
            <% end %>
          </p>
        </div>

        <div :for={warning <- @result.warnings} class="flex items-center gap-2 text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <span class="text-xs">{warning}</span>
        </div>

        <div :for={error <- @result.errors} class="flex items-center gap-2 text-error">
          <.icon name="hero-x-circle" class="size-4 shrink-0" />
          <span class="text-xs">{error}</span>
        </div>
      </div>

      <button
        type="button"
        phx-click="close"
        phx-target={@myself}
        class="btn btn-primary btn-lg w-full rounded-2xl"
      >
        Fechar
      </button>
    </div>
    """
  end
end
