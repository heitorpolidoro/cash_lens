defmodule CashLensWeb.ReimbursementLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  import CashLensWeb.Formatters

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Gestão de Reembolsos
        <:subtitle>Acompanhe despesas reembolsáveis e concilie com os recebimentos.</:subtitle>
      </.header>

      <!-- Resumo Macro -->
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="text-xs font-black uppercase opacity-40 mb-1">Total a Receber</h2>
            <p class="text-3xl font-black text-primary">{format_currency(@total_pending)}</p>
            <p class="text-[10px] opacity-50 font-bold uppercase mt-2">{@pending_count} despesas aguardando</p>
          </div>
        </div>
        
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="text-xs font-black uppercase opacity-40 mb-1">Solicitados (Aguardando Plano)</h2>
            <p class="text-3xl font-black text-info">{format_currency(@total_requested)}</p>
            <p class="text-[10px] opacity-50 font-bold uppercase mt-2">{@requested_count} pedidos enviados</p>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="text-xs font-black uppercase opacity-40 mb-1">Recuperado este Mês</h2>
            <p class="text-3xl font-black text-success">{format_currency(@total_recovered_month)}</p>
            <p class="text-[10px] opacity-50 font-bold uppercase mt-2">Dinheiro que voltou para o bolso</p>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <!-- Coluna A: Despesas Pendentes -->
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-0">
            <div class="p-6 border-b border-base-200">
              <h2 class="card-title text-base-content uppercase text-xs opacity-50 font-black">Despesas Pendentes</h2>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full text-xs">
                <thead>
                  <tr>
                    <th>Data</th>
                    <th>Descrição</th>
                    <th class="text-right">Valor</th>
                    <th class="text-center">Ação</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for tx <- @pending_list do %>
                    <tr class="hover group">
                      <td class="whitespace-nowrap font-medium">{format_date(tx.date)}</td>
                      <td>
                        <div class="flex flex-col">
                          <span class="font-bold">{tx.description}</span>
                          <span class="text-[10px] opacity-50 uppercase font-bold">{tx.account.name}</span>
                        </div>
                      </td>
                      <td class="text-right font-black text-error">{format_currency(tx.amount)}</td>
                      <td class="text-center">
                        <button phx-click="mark_requested" phx-value-id={tx.id} class="btn btn-ghost btn-xs text-info" title="Marcar como Solicitado">
                          <.icon name="hero-paper-airplane" class="size-4" />
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <%= if Enum.empty?(@pending_list) do %>
                    <tr><td colspan="4" class="text-center py-10 opacity-30 italic">Nenhuma despesa pendente.</td></tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Coluna B: Solicitados -->
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-0">
            <div class="p-6 border-b border-base-200">
              <h2 class="card-title text-base-content uppercase text-xs opacity-50 font-black">Solicitados (Em andamento)</h2>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full text-xs">
                <thead>
                  <tr>
                    <th>Data</th>
                    <th>Descrição</th>
                    <th class="text-right">Valor</th>
                    <th class="text-center">Conciliar</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for tx <- @requested_list do %>
                    <tr class="hover group">
                      <td class="whitespace-nowrap font-medium">{format_date(tx.date)}</td>
                      <td>
                        <div class="flex flex-col">
                          <span class="font-bold">{tx.description}</span>
                          <span class="text-[10px] opacity-50 uppercase font-bold">{tx.account.name}</span>
                        </div>
                      </td>
                      <td class="text-right font-black text-info">{format_currency(tx.amount)}</td>
                      <td class="text-center">
                        <button phx-click="open_linker" phx-value-id={tx.id} class="btn btn-ghost btn-xs text-success" title="Vincular Recebimento">
                          <.icon name="hero-link" class="size-4" />
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <%= if Enum.empty?(@requested_list) do %>
                    <tr><td colspan="4" class="text-center py-10 opacity-30 italic">Nenhum pedido em andamento.</td></tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Modal de Vínculo (Inverso: selecionar o crédito para o débito) -->
    <.modal :if={@show_linker_modal} id="linker-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-success">Vincular Recebimento</h2>
        <p class="text-xs opacity-60 mb-6">Qual destas entradas de dinheiro é o reembolso de <strong>{format_currency(@selected_expense.amount)}</strong> para <strong>{@selected_expense.description}</strong>?</p>
        
        <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
          <%= if Enum.empty?(@available_credits) do %>
            <div class="text-center py-10 opacity-40 italic">Nenhuma entrada de dinheiro (crédito) recente encontrada para vincular.</div>
          <% end %>
          
          <%= for credit <- @available_credits do %>
            <button type="button" phx-click="confirm_link" phx-value-credit-id={credit.id} class="w-full text-left flex items-center justify-between p-4 border-2 border-base-300 rounded-2xl hover:border-success hover:bg-success/5 transition-all group">
              <div class="flex flex-col">
                <span class="text-[10px] font-bold uppercase opacity-50">{format_date(credit.date)} — {credit.account.name}</span>
                <span class="font-black text-lg group-hover:text-success">{credit.description}</span>
              </div>
              <div class="text-right">
                <span class="font-black text-lg text-success">{format_currency(credit.amount)}</span>
              </div>
            </button>
          <% end %>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, fetch_data(socket) |> assign(:show_linker_modal, false) |> assign(:selected_expense, nil)}
  end

  @impl true
  def handle_event("mark_requested", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: "requested"})
    {:noreply, fetch_data(socket)}
  end

  @impl true
  def handle_event("open_linker", %{"id" => id}, socket) do
    expense = Transactions.get_transaction!(id)
    # Sugere créditos recentes que não estão vinculados
    credits = Transactions.list_transactions(%{"amount_min" => 0}) 
              |> Enum.filter(&is_nil(&1.reimbursement_link_key) && Decimal.gt?(&1.amount, 0))
              |> Enum.take(10)

    {:noreply, socket |> assign(:show_linker_modal, true) |> assign(:selected_expense, expense) |> assign(:available_credits, credits)}
  end

  @impl true
  def handle_event("confirm_link", %{"credit-id" => credit_id}, socket) do
    expense = socket.assigns.selected_expense
    credit = Transactions.get_transaction!(credit_id)
    link_key = Ecto.UUID.generate()

    {:ok, _} = Transactions.update_transaction(expense, %{reimbursement_status: "paid", reimbursement_link_key: link_key})
    {:ok, _} = Transactions.update_transaction(credit, %{reimbursement_status: "paid", reimbursement_link_key: link_key})

    {:noreply, socket |> assign(:show_linker_modal, false) |> put_flash(:info, "Reembolso conciliado!") |> fetch_data()}
  end

  @impl true
  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, :show_linker_modal, false)}

  defp fetch_data(socket) do
    pending = Transactions.list_transactions(%{"reimbursement_status" => "pending"})
    requested = Transactions.list_transactions(%{"reimbursement_status" => "requested"})
    
    total_pending = Enum.reduce(pending, Decimal.new("0"), &Decimal.add(&2, &1.amount)) |> Decimal.abs()
    total_requested = Enum.reduce(requested, Decimal.new("0"), &Decimal.add(&2, &1.amount)) |> Decimal.abs()

    socket
    |> assign(:pending_list, pending)
    |> assign(:requested_list, requested)
    |> assign(:total_pending, total_pending)
    |> assign(:total_requested, total_requested)
    |> assign(:pending_count, length(pending))
    |> assign(:requested_count, length(requested))
    |> assign(:total_recovered_month, Decimal.new("0")) # TODO: Implement monthly recovery sum
  end
end
