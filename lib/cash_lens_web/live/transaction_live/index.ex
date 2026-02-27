defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLens.Accounts
  alias CashLens.Categories
  alias CashLens.Parsers.Ingestor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Transações
        <:actions>
          <button type="button" phx-click="confirm_delete_all" class="btn btn-error btn-outline">
            <.icon name="hero-trash" class="size-4 mr-1" /> Limpar Tudo
          </button>
          <button type="button" phx-click="open_import" class="btn btn-outline border-base-300">
            <.icon name="hero-arrow-up-tray" class="size-4 mr-1" /> Importar Extratos
          </button>
          <.link navigate={~p"/transactions/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="size-4 mr-1" /> Nova Transação
            </.button>
          </.link>
        </:actions>
      </.header>

      <!-- Tabela com Filtros -->
      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <form id="filter-form" phx-change="filter">
          <table class="table table-zebra w-full text-xs">
            <thead class="bg-base-200/50">
              <tr>
                <th class="w-40"><div class="flex flex-col gap-1"><span>Data</span><input type="date" name="date" value={@filters["date"]} class="input input-bordered input-xs font-normal w-full" /></div></th>
                <th><div class="flex flex-col gap-1"><span>Descrição</span><input type="text" name="search" value={@filters["search"]} placeholder="Buscar..." class="input input-bordered input-xs font-normal w-full" phx-debounce="300" /></div></th>
                <th class="w-32 text-right"><div class="flex flex-col gap-1"><span>Valor</span><input type="number" name="amount" value={@filters["amount"]} placeholder="0.00" step="any" class="input input-bordered input-xs font-normal w-full text-right" phx-debounce="300" /></div></th>
                <th class="w-40"><div class="flex flex-col gap-1"><span>Categoria</span><select name="category_id" class="select select-bordered select-xs font-normal w-full"><option value="">Todas</option><%= for category <- @categories do %><option value={category.id} selected={@filters["category_id"] == category.id}>{category.name}</option><% end %></select></div></th>
                <th class="w-40"><div class="flex flex-col gap-1"><span>Conta</span><select name="account_id" class="select select-bordered select-xs font-normal w-full"><option value="">Todas</option><%= for account <- @accounts do %><option value={account.id} selected={@filters["account_id"] == account.id}>{account.name}</option><% end %></select></div></th>
                <th class="w-16"><div class="flex flex-col gap-1 items-center"><span class="opacity-0">Reset</span><button type="button" phx-click="clear_filters" class="btn btn-ghost btn-xs text-error p-0"><.icon name="hero-x-circle" class="size-4" /></button></div></th>
              </tr>
            </thead>
            <tbody id="transactions" phx-update="stream">
              <tr :for={{id, transaction} <- @streams.transactions} id={id} class="hover group border-b border-base-200">
                <td class="whitespace-nowrap">
                  <div class="flex flex-col">
                    <span class="font-medium text-base-content">{format_date(transaction.date)}</span>
                    <span :if={transaction.time} class="text-[10px] opacity-50">{format_time(transaction.time)}</span>
                  </div>
                </td>
                <td class="max-w-md truncate">{transaction.description}</td>
                <td class={"text-right font-bold #{if Decimal.lt?(transaction.amount, 0), do: "text-error", else: "text-success"}"}>
                  {format_currency(transaction.amount)}
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <form phx-change="update_category" class="m-0 p-0">
                      <input type="hidden" name="transaction_id" value={transaction.id} />
                      <select name="category_id" class={["select select-bordered select-xs w-36 max-w-xs font-medium uppercase text-[10px]", is_nil(transaction.category_id) && "select-warning bg-warning/10 text-warning-content"]}>
                        <option value="">Pendente</option>
                        <%= for category <- @categories do %>
                          <option value={category.id} selected={transaction.category_id == category.id}>{category.name}</option>
                        <% end %>
                      </select>
                    </form>
                    <%= if transaction.category && transaction.category.slug == "transfer" do %>
                      <%= if transaction.transfer_key do %>
                        <.icon name="hero-link" class="size-3 text-primary" />
                      <% else %>
                        <.icon name="hero-exclamation-triangle" class="size-3 text-warning" />
                      <% end %>
                    <% end %>
                  </div>
                </td>
                <td class="text-xs opacity-60">{if transaction.account, do: transaction.account.name, else: "..."}</td>
                <td class="text-right">
                  <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                    <.link navigate={~p"/transactions/#{transaction}/edit"} class="btn btn-ghost btn-xs px-1" phx-click-stop><.icon name="hero-pencil" class="size-3" /></.link>
                    <button type="button" phx-click="confirm_delete" phx-value-id={transaction.id} phx-click-stop class="btn btn-ghost btn-xs text-error px-1"><.icon name="hero-trash" class="size-3" /></button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </form>
        
        <!-- Sentinela para o Infinite Scroll -->
        <div id="infinite-scroll-sentinel" phx-hook="InfiniteScroll" class="py-4 flex justify-center">
          <div :if={not @end_of_list?} class="loading loading-spinner loading-sm text-primary opacity-20"></div>
          <p :if={@end_of_list?} class="text-[10px] uppercase font-bold opacity-20">Fim da lista</p>
        </div>
      </div>
    </div>

    <!-- Modais omitidos para brevidade mas permanecem no arquivo real -->
    <.modal :if={@show_import_modal} id="import-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter text-primary">Importar Extratos</h2>
        <form id="upload-form" phx-submit="save_import" phx-change="validate_import" class="space-y-8">
          <div class="form-control w-full">
            <label class="label mb-2"><span class="label-text font-black text-lg">1. Selecione os Arquivos</span></label>
            <div class="flex flex-col gap-4">
              <div class="flex items-center justify-center border-4 border-dashed border-base-300 rounded-3xl py-10 bg-base-200/30 hover:bg-base-200 transition-all cursor-pointer relative" phx-drop-target={@uploads.statement.ref}>
                <label class="cursor-pointer text-center w-full">
                  <div :if={Enum.empty?(@uploads.statement.entries)} class="space-y-2">
                    <.icon name="hero-folder-plus" class="size-12 opacity-10 mx-auto" />
                    <p class="text-xs opacity-40 font-bold uppercase">Clique nos botões abaixo ou arraste</p>
                    <div class="flex justify-center gap-2 mt-4">
                      <button type="button" class="btn btn-sm btn-outline border-base-300" phx-click={JS.dispatch("click", to: "input[data-phx-hook='Phoenix.LiveFileUpload']")}>Selecionar Arquivos</button>
                      <button type="button" class="btn btn-sm btn-outline border-base-300" phx-click={JS.dispatch("click", to: "#file-input-dir")}>Selecionar Pasta</button>
                    </div>
                  </div>
                  <div class="hidden">
                    <.live_file_input upload={@uploads.statement} />
                    <input type="file" id="file-input-dir" webkitdirectory directory phx-hook="DirectoryUpload" />
                  </div>
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 px-4 max-h-48 overflow-y-auto">
                    <%= for entry <- @uploads.statement.entries do %>
                      <div class="flex items-center gap-2 bg-primary/5 text-primary p-2 rounded-xl text-[10px] border border-primary/10">
                        <.icon name="hero-check-circle" class="size-4" />
                        <span class="flex-1 text-left font-bold truncate">{entry.client_name}</span>
                        <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref} class="btn btn-ghost btn-xs min-h-0 h-6"><.icon name="hero-x-mark" class="size-3" /></button>
                      </div>
                    <% end %>
                  </div>
                </label>
              </div>
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="form-control w-full space-y-4 animate-in slide-in-from-bottom-4">
            <label class="label"><span class="label-text font-black text-lg">2. Para qual conta vão estes arquivos?</span></label>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <%= for account <- @import_accounts do %>
                <label class="flex items-center gap-4 p-4 border-2 border-base-300 rounded-2xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input type="radio" name="account_id" value={account.id} class="radio radio-primary radio-md" required />
                  <div class="flex flex-col">
                    <span class="font-black text-md">{account.name}</span>
                    <span class="text-[10px] opacity-50 font-bold uppercase">{account.bank}</span>
                  </div>
                </label>
              <% end %>
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="flex justify-end pt-6 border-t border-base-200">
            <button type="submit" class="btn btn-primary btn-lg w-full rounded-2xl shadow-xl shadow-primary/20" phx-disable-with="Processando lote...">
              <.icon name="hero-bolt" class="size-5 mr-2" /> Finalizar e Importar Tudo
            </button>
          </div>
        </form>
      </div>
    </.modal>

    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">{@confirm_modal.title}</h2>
        <p class="text-base-content/60 mb-10">{@confirm_modal.message}</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">Sim, Apagar</button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">Cancelar</button>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    accounts = Accounts.list_accounts()
    {:ok,
     socket
     |> assign(:page_title, "Transações")
     |> assign(:show_import_modal, false)
     |> assign(:confirm_modal, nil)
     |> assign(:accounts, accounts)
     |> assign(:import_accounts, Enum.filter(accounts, & &1.accepts_import))
     |> assign(:categories, Categories.list_categories())
     |> assign(:filters, %{"search" => "", "account_id" => "", "category_id" => "", "date" => "", "amount" => ""})
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> stream(:transactions, Transactions.list_transactions())
     |> allow_upload(:statement, accept: ~w(.csv), max_entries: 100)}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    if socket.assigns.end_of_list? do
      {:noreply, socket}
    else
      next_page = socket.assigns.page + 1
      new_transactions = Transactions.list_transactions(socket.assigns.filters, next_page)
      
      {:noreply,
       socket
       |> assign(:page, next_page)
       |> assign(:end_of_list?, Enum.empty?(new_transactions))
       |> stream_insert_many(:transactions, new_transactions)}
    end
  end

  defp stream_insert_many(socket, stream_name, items) do
    Enum.reduce(items, socket, fn item, acc ->
      stream_insert(acc, stream_name, item)
    end)
  end

  # Outros eventos permanecem os mesmos...
  @impl true
  def handle_event("open_import", _params, socket), do: {:noreply, assign(socket, :show_import_modal, true)}
  @impl true
  def handle_event("close_modal", _params, socket), do: {:noreply, socket |> assign(:show_import_modal, false) |> assign(:confirm_modal, nil)}
  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket), do: {:noreply, cancel_upload(socket, :statement, ref)}

  @impl true
  def handle_event("confirm_delete_all", _params, socket) do
    confirm = %{title: "Limpar tudo?", message: "Você está prestes a apagar TODAS as transações do sistema.", action: "delete_all"}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{title: "Excluir transação?", message: "Deseja realmente apagar este registro?", action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()
    {:noreply, socket |> assign(:confirm_modal, nil) |> put_flash(:info, "Limpeza concluída.") |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters), reset: true)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.delete_transaction(transaction)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:transactions, transaction)}
  end

  @impl true
  def handle_event("update_category", %{"transaction_id" => id, "category_id" => category_id}, socket) do
    category_id = if category_id == "", do: nil, else: category_id
    case Transactions.update_transaction_category(id, category_id) do
      {:ok, updated_tx} -> {:noreply, stream_insert(socket, :transactions, Transactions.get_transaction!(updated_tx.id))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Falha ao atualizar")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filters, params)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> stream(:transactions, Transactions.list_transactions(params, 1), reset: true)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"search" => "", "account_id" => "", "category_id" => "", "date" => "", "amount" => ""}
    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> stream(:transactions, Transactions.list_transactions(filters, 1), reset: true)}
  end

  @impl true
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    all_affected_periods = 
      consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
        content = File.read!(path)
        content = if String.valid?(content), do: content, else: :unicode.characters_to_binary(content, :latin1, :utf8)
        
        case Ingestor.parse(content, entry.client_name) do
          {:error, reason} -> {:postpone, reason}
          transactions_data ->
            periods = Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
              data |> Map.put(:account_id, account_id) |> CashLens.Transactions.AutoCategorizer.categorize() |> Transactions.create_transaction()
              acc = MapSet.put(acc, {account_id, data.date.month, data.date.year})
              description = String.upcase(data.description || "")
              cond do
                String.contains?(description, "BB MM OURO") ->
                  case Accounts.get_account_by_name("BB MM Ouro") do
                    nil -> acc
                    a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
                  end
                String.contains?(description, ["BB RENDE FÁCIL", "BB RENDE FACIL"]) ->
                  case Accounts.get_account_by_name("BB Rende Fácil") do
                    nil -> acc
                    a -> MapSet.put(acc, {a.id, data.date.month, data.date.year})
                  end
                true -> acc
              end
            end)
            {:ok, periods}
        end
      end)

    all_affected_periods
    |> List.flatten()
    |> Enum.reduce(MapSet.new(), fn set, acc -> MapSet.union(acc, set) end)
    |> MapSet.to_list()
    |> Enum.each(fn {acc_id, month, year} ->
      CashLens.Accounting.calculate_monthly_balance(acc_id, year, month)
    end)

    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:page, 1)
     |> assign(:end_of_list?, false)
     |> put_flash(:info, "Importação concluída e balanços atualizados!")
     |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters, 1), reset: true)}
  end
end
