defmodule CashLensWeb.TransactionLive.ImportModalComponent do
  use CashLensWeb, :live_component

  alias CashLens.Accounts
  alias CashLens.Parsers.Ingestor

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:import_accounts, fn ->
        Accounts.list_accounts() |> Enum.filter(& &1.accepts_import)
      end)
      |> assign_new(:import_account_id, fn -> nil end)
      |> allow_upload(:statement,
        accept: ~w(.csv .pdf .ofx),
        max_entries: 100,
        max_file_size: 10_000_000
      )
      |> allow_upload(:directory_statement,
        accept: ~w(.csv .pdf .ofx),
        max_entries: 1000,
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

    results =
      consume_uploaded_entries(socket, :statement, &copy_to_temp/2) ++
        consume_uploaded_entries(socket, :directory_statement, &copy_to_temp/2)

    case results do
      [] ->
        send(self(), {:import_error, "No file selected."})
        {:noreply, socket}

      entries ->
        file_paths = extract_file_paths(entries)

        start_bulk_import(account, {:files, file_paths})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("import_directory", %{"account_id" => account_id}, socket) do
    account = Accounts.get_account!(account_id)
    dir_path = "/app/statements"

    start_bulk_import(account, {:directory, dir_path})
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_import_modal)
    {:noreply, socket}
  end

  defp extract_file_paths(entries) do
    for entry <- entries do
      case entry do
        {:ok, path} -> path
        path -> path
      end
    end
  end

  defp copy_to_temp(%{path: path}, entry) do
    filename = Path.basename(entry.client_name)
    dest = Path.join(System.tmp_dir!(), "#{entry.uuid}-#{filename}")
    File.cp!(path, dest)
    {:ok, dest}
  end

  defp start_bulk_import(account, source) do
    pid = self()

    process_import = fn ->
      result = process_source(account, source)

      case result do
        {:ok, count} -> send(pid, {:import_success, count})
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

  defp process_source(account, {:files, file_paths}) do
    results =
      Enum.map(file_paths, fn path ->
        res = Ingestor.import_file(account, path)
        File.rm(path)
        res
      end)

    summarize_import_results(results)
  end

  defp process_source(account, {:directory, dir_path}) do
    Ingestor.import_directory(account, dir_path)
  end

  defp summarize_import_results(results) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    total_count = successes |> Enum.map(fn {:ok, count} -> count end) |> Enum.sum()

    if Enum.empty?(errors) do
      {:ok, total_count}
    else
      {:error,
       "#{length(errors)} files failed. Total transactions from successful files: #{total_count}"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal :if={@show} id="import-modal" show on_cancel={JS.push("close", target: @myself)}>
        <div class="p-2">
          <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">
            Import Statements
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
                  1. Select Destination Account
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
                            <%!-- coveralls-ignore-next-line --%>
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
              </div>
            </div>

            <div class="form-control w-full mb-8">
              <label class="label flex justify-between items-end">
                <span class="label-text font-black uppercase opacity-40 text-[10px]">
                  2. Select Source
                </span>
              </label>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-2">
                <!-- Dropzone for Files -->
                <div class="p-6 border-2 border-dashed border-base-300 rounded-3xl bg-base-200/50 flex flex-col items-center justify-center group hover:border-primary transition-all cursor-pointer relative min-h-[160px]">
                  <.icon
                    name="hero-document-plus"
                    class="size-8 opacity-20 mb-2 group-hover:text-primary group-hover:opacity-100 transition-all"
                  />
                  <p class="text-xs font-bold opacity-40 text-center">
                    Click to select<br />individual files
                  </p>
                  <.live_file_input
                    upload={@uploads.statement}
                    class="absolute inset-0 opacity-0 cursor-pointer w-full h-full z-10"
                  />
                </div>
                
    <!-- Dropzone for Folders -->
                <div class="p-6 border-2 border-dashed border-base-300 rounded-3xl bg-base-200/50 flex flex-col items-center justify-center group hover:border-primary transition-all cursor-pointer relative min-h-[160px]">
                  <.icon
                    name="hero-folder-plus"
                    class="size-8 opacity-20 mb-2 group-hover:text-primary group-hover:opacity-100 transition-all"
                  />
                  <p class="text-xs font-bold opacity-40 text-center">
                    Click to select<br />an entire folder
                  </p>
                  <.live_file_input
                    upload={@uploads.directory_statement}
                    webkitdirectory
                    class="absolute inset-0 opacity-0 cursor-pointer w-full h-full z-10"
                  />
                </div>
              </div>

              <div
                :if={
                  !Enum.empty?(@uploads.statement.entries) ||
                    !Enum.empty?(@uploads.directory_statement.entries)
                }
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
                    phx-click={
                      JS.push("cancel-upload",
                        value: %{ref: entry.ref, upload: "statement"},
                        target: @myself
                      )
                    }
                    class="btn btn-ghost btn-xs text-error"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
                <div
                  :for={entry <- @uploads.directory_statement.entries}
                  class="p-2 bg-base-100 rounded-lg border border-base-300 flex items-center justify-between animate-in fade-in zoom-in-95"
                >
                  <div class="flex items-center gap-2 min-w-0">
                    <.icon name="hero-document-text" class="size-4 text-primary shrink-0" />
                    <span class="text-[10px] font-bold truncate">{entry.client_name}</span>
                  </div>
                  <button
                    type="button"
                    phx-click={
                      JS.push("cancel-upload",
                        value: %{ref: entry.ref, upload: "directory_statement"},
                        target: @myself
                      )
                    }
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
              phx-disable-with="Processing..."
              disabled={
                Enum.empty?(@uploads.statement.entries) &&
                  Enum.empty?(@uploads.directory_statement.entries)
              }
            >
              Start Import
            </button>
          </form>
        </div>
      </.modal>
    </div>
    """
  end
end
