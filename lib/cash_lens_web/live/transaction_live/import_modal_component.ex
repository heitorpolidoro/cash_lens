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
        send(self(), {:import_error, "No file selected."})
        {:noreply, socket}

      results ->
        file_paths =
          Enum.map(results, fn
            {:ok, path} -> path
            path when is_binary(path) -> path
          end)

        start_bulk_import(account, {:files, file_paths})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), :close_import_modal)
    {:noreply, socket}
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

  defp start_bulk_import(account, source) do
    pid = self()

    process_import = fn ->
      result =
        case source do
          {:files, file_paths} ->
            file_paths
            |> Enum.map(&import_and_cleanup(account, &1))
            |> summarize_import_results()
        end

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

  defp import_and_cleanup(account, path) do
    res = Ingestor.import_file(account, path)
    File.rm(path)
    res
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
                      Add Account
                    </span>
                  </div>
                </.link>
              </div>
            </div>

            <div class="form-control w-full mb-8">
              <label class="label">
                <span class="label-text font-black uppercase opacity-40 text-[10px]">
                  2. Select Source
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
                  Drag your files or click to select
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
              phx-disable-with="Processing..."
              disabled={Enum.empty?(@uploads.statement.entries)}
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
