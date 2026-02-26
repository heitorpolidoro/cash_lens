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
          <button phx-click="confirm_delete_all" class="btn btn-error btn-outline">
            <.icon name="hero-trash" class="mr-1" /> Limpar Tudo
          </button>
          <button phx-click="open_import" class="btn btn-outline">
            <.icon name="hero-arrow-up-tray" class="mr-1" /> Importar Extrato
          </button>
          <.link navigate={~p"/transactions/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Transação
            </.button>
          </.link>
        </:actions>
      </.header>

      <!-- Tabela com Filtros no Cabeçalho -->
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
                <td class="whitespace-nowrap font-medium">{format_date(transaction.date)}</td>
                <td class="max-w-md truncate">{transaction.description}</td>
                <td class={"text-right font-bold #{if Decimal.lt?(transaction.amount, 0), do: "text-error", else: "text-success"}"}>
                  {format_currency(transaction.amount)}
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <div class="badge badge-outline text-[10px] uppercase opacity-70">{if transaction.category, do: transaction.category.name, else: "Pendente"}</div>
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
                    <.link navigate={~p"/transactions/#{transaction}/edit"} class="btn btn-ghost btn-xs px-1"><.icon name="hero-pencil" class="size-3" /></.link>
                    <button phx-click="confirm_delete" phx-value-id={transaction.id} class="btn btn-ghost btn-xs text-error px-1"><.icon name="hero-trash" class="size-3" /></button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </form>
      </div>
    </div>

    <!-- Modal de Importação -->
    <.modal :if={@show_import_modal} id="import-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-6 uppercase tracking-tighter">Importar Extrato</h2>
        <form id="upload-form" phx-submit="save_import" phx-change="validate_import" class="space-y-8">
          <div class="form-control w-full">
            <label class="label"><span class="label-text font-black text-lg">1. Selecione o arquivo CSV</span></label>
            <div class="flex items-center justify-center border-4 border-dashed border-base-300 rounded-3xl py-12 bg-base-200/30 hover:bg-base-200 transition-all cursor-pointer" phx-drop-target={@uploads.statement.ref}>
              <label class="cursor-pointer text-center w-full">
                <div :if={Enum.empty?(@uploads.statement.entries)}>
                  <.icon name="hero-document-plus" class="size-16 opacity-10 mb-4" />
                  <p class="text-sm opacity-40 font-bold uppercase tracking-widest">Arraste ou clique para selecionar</p>
                </div>
                <.live_file_input upload={@uploads.statement} class="hidden" />
                <%= for entry <- @uploads.statement.entries do %>
                  <div class="flex flex-col items-center justify-center gap-2 text-primary">
                    <.icon name="hero-check-badge" class="size-16 animate-bounce" />
                    <span class="text-lg font-black">{entry.client_name}</span>
                  </div>
                <% end %>
              </label>
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="form-control w-full space-y-4 animate-in slide-in-from-bottom-4 duration-500">
            <label class="label"><span class="label-text font-black text-lg text-primary">2. Para qual conta vai esse dinheiro?</span></label>
            <div class="grid grid-cols-1 gap-3">
              <%= for account <- @import_accounts do %>
                <label class="flex items-center gap-4 p-4 border-2 border-base-300 rounded-2xl cursor-pointer hover:bg-base-200 transition-all has-[:checked]:border-primary has-[:checked]:bg-primary/5 has-[:checked]:ring-4 has-[:checked]:ring-primary/10">
                  <input type="radio" name="account_id" value={account.id} class="radio radio-primary radio-lg" required />
                  <div class="flex flex-col">
                    <span class="font-black text-lg">{account.name}</span>
                    <span class="text-sm opacity-50 font-medium tracking-wide">{account.bank}</span>
                  </div>
                </label>
              <% end %>
            </div>
            <div :if={Enum.empty?(@import_accounts)} class="text-center py-4 text-error font-bold">
              Nenhuma conta configurada para aceitar importação.
            </div>
          </div>
          <div :if={Enum.any?(@uploads.statement.entries)} class="flex justify-end pt-6">
            <button type="submit" class="btn btn-primary btn-lg w-full rounded-2xl shadow-xl shadow-primary/20" phx-disable-with="Processando tudo...">
              <.icon name="hero-bolt" class="size-5 mr-2" /> Finalizar e Importar
            </button>
          </div>
        </form>
      </div>
    </.modal>

    <!-- Modal de Confirmação de Exclusão -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">{@confirm_modal.title}</h2>
        <p class="text-base-content/60 mb-10">{@confirm_modal.message}</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">Confirmar e Apagar</button>
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
     |> stream(:transactions, Transactions.list_transactions())
     |> allow_upload(:statement, accept: ~w(.csv), max_entries: 1)}
  end

  @impl true
  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, :show_import_modal, true)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:show_import_modal, false) |> assign(:confirm_modal, nil)}
  end

  @impl true
  def handle_event("confirm_delete_all", _params, socket) do
    confirm = %{
      title: "Limpar tudo?",
      message: "Você está prestes a apagar TODAS as transações do sistema. Esta ação não tem volta!",
      action: "delete_all"
    }
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{
      title: "Excluir transação?",
      message: "Deseja realmente apagar este registro?",
      action: JS.push("delete", value: %{id: id})
    }
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("delete_all", _params, socket) do
    Transactions.delete_all_transactions()
    {:noreply,
     socket
     |> assign(:confirm_modal, nil)
     |> put_flash(:info, "Todas as transações foram apagadas.")
     |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters), reset: true)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.delete_transaction(transaction)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:transactions, transaction)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filters, params)
     |> stream(:transactions, Transactions.list_transactions(params), reset: true)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"search" => "", "account_id" => "", "category_id" => "", "date" => "", "amount" => ""}
    {:noreply,
     socket
     |> assign(:filters, filters)
     |> stream(:transactions, Transactions.list_transactions(filters), reset: true)}
  end

  @impl true
  def handle_event("validate_import", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    # Track which (account, month, year) were affected
    affected_periods = 
      consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
        content = File.read!(path)
        content = if String.valid?(content), do: content, else: :unicode.characters_to_binary(content, :latin1, :utf8)
        
        case Ingestor.parse(content, entry.client_name) do
          {:error, reason} -> {:postpone, reason}
          transactions_data ->
            periods = Enum.reduce(transactions_data, MapSet.new(), fn data, acc ->
              # 1. Create transaction
              data
              |> Map.put(:account_id, account_id)
              |> CashLens.Transactions.AutoCategorizer.categorize()
              |> Transactions.create_transaction()

              # 2. Track primary account period
              acc = MapSet.put(acc, {account_id, data.date.month, data.date.year})

              # 3. Track virtual twin accounts (BB investments)
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

    # 4. Correctly iterate the periods and update balances
    Enum.each(affected_periods, fn periods_set ->
      Enum.each(MapSet.to_list(periods_set), fn {acc_id, month, year} ->
        IO.puts("Updating balance for account #{acc_id} at #{month}/#{year}")
        CashLens.Accounting.calculate_monthly_balance(acc_id, year, month)
      end)
    end)

    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> put_flash(:info, "Importação concluída e balanços atualizados!")
     |> stream(:transactions, Transactions.list_transactions(socket.assigns.filters), reset: true)}
  end
end
