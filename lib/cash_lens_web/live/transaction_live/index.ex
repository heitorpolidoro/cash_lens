defmodule CashLensWeb.TransactionLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  alias CashLens.Parsers.Ingestor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Transações
        <:actions>
          <.link navigate={~p"/transactions/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Transação
            </.button>
          </.link>
        </:actions>
      </.header>

      <!-- Área de Importação -->
      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-sm uppercase opacity-50 mb-4">Importar Extrato</h2>
          
          <form id="upload-form" phx-submit="save_import" phx-change="validate_import" class="space-y-6">
            <!-- PASSO 1: Selecionar Arquivo -->
            <div class="form-control w-full">
              <label class="label"><span class="label-text font-bold text-primary">1. Selecione o arquivo CSV</span></label>
              <div class="flex items-center justify-center border-2 border-dashed border-base-300 rounded-xl py-8 bg-base-200/30 hover:bg-base-200 transition-colors" phx-drop-target={@uploads.statement.ref}>
                <label class="cursor-pointer text-center w-full">
                  <div :if={Enum.empty?(@uploads.statement.entries)}>
                    <.icon name="hero-cloud-arrow-up" class="size-8 opacity-20 mb-2" />
                    <p class="text-xs opacity-60 font-medium">Arraste ou clique para selecionar</p>
                  </div>
                  <.live_file_input upload={@uploads.statement} class="hidden" />
                  
                  <%= for entry <- @uploads.statement.entries do %>
                    <div class="flex items-center justify-center gap-2 text-blue-600 font-bold">
                      <.icon name="hero-check-circle" class="size-5" />
                      <span>{entry.client_name}</span>
                    </div>
                  <% end %>
                </label>
              </div>
            </div>

            <!-- PASSO 2: Selecionar Conta -->
            <div :if={Enum.any?(@uploads.statement.entries)} class="form-control w-full space-y-2">
              <label class="label"><span class="label-text font-bold text-primary">2. Selecione a Conta de Destino</span></label>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                <%= for account <- @accounts do %>
                  <label class="label cursor-pointer flex items-center gap-3 p-4 bg-base-100 border border-base-300 rounded-xl hover:bg-base-200 transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                    <input type="radio" name="account_id" value={account.id} class="radio radio-primary" required />
                    <div class="flex flex-col">
                      <span class="font-bold text-sm">{account.name}</span>
                      <span class="text-xs opacity-60">{account.bank}</span>
                    </div>
                  </label>
                <% end %>
              </div>
            </div>

            <!-- Botão de Ação -->
            <div :if={Enum.any?(@uploads.statement.entries)} class="flex justify-end pt-4 border-t border-base-200">
              <button type="submit" class="btn btn-primary" phx-disable-with="Importando...">
                Confirmar e Importar
              </button>
            </div>
          </form>
        </div>
      </div>

              <.table
                id="transactions"
                rows={@streams.transactions}
                row_click={fn {_id, transaction} -> JS.navigate(~p"/transactions/#{transaction}") end}
              >
                <:col :let={{_id, transaction}} label="Data">{format_date(transaction.date)}</:col>
                <:col :let={{_id, transaction}} label="Descrição">{transaction.description}</:col>
                <:col :let={{_id, transaction}} label="Valor">
                  <span class={if Decimal.lt?(transaction.amount, 0), do: "text-error font-bold", else: "text-success font-bold"}>
                    {format_currency(transaction.amount)}
                  </span>
                </:col>
                <:col :let={{_id, transaction}} label="Categoria">
      
          <div class="badge badge-outline opacity-70">{transaction.category || "Pendente"}</div>
        </:col>
        <:action :let={{_id, transaction}}>
          <.link navigate={~p"/transactions/#{transaction}/edit"}>Editar</.link>
        </:action>
        <:action :let={{id, transaction}}>
          <.link
            phx-click={JS.push("delete", value: %{id: transaction.id}) |> hide("##{id}")}
            data-confirm="Deseja excluir esta transação?"
          >
            Excluir
          </.link>
        </:action>
      </.table>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transações")
     |> assign(:accounts, CashLens.Accounts.list_accounts())
     |> stream(:transactions, Transactions.list_transactions())
     |> allow_upload(:statement, accept: ~w(.csv), max_entries: 1)}
  end

  @impl true
  def handle_event("validate_import", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_import", %{"account_id" => account_id}, socket) do
    IO.puts("Starting import for account: #{account_id}")
    
    consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
      content = File.read!(path)
      
      content = 
        if String.valid?(content), do: content, else: :unicode.characters_to_binary(content, :latin1, :utf8)
      
      case Ingestor.parse(content, entry.client_name) do
        {:error, reason} ->
          IO.puts("Parser error: #{reason}")
          {:postpone, reason}
          
        transactions_data ->
          IO.puts("Parsed #{length(transactions_data)} transactions.")
          
          results = Enum.map(transactions_data, fn data ->
            params = Map.put(data, :account_id, account_id)
            case Transactions.create_transaction(params) do
              {:ok, tx} -> {:ok, tx}
              {:error, changeset} -> 
                IO.inspect(changeset.errors, label: "Transaction creation failed")
                {:error, changeset}
            end
          end)
          
          {:ok, results}
      end
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Processamento concluído!")
     |> stream(:transactions, Transactions.list_transactions(), reset: true)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.delete_transaction(transaction)

    {:noreply, stream_delete(socket, :transactions, transaction)}
  end
end
