defmodule CashLensWeb.ReimbursementLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions
  import CashLensWeb.Formatters

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 relative">
      <div
        :if={MapSet.size(@selected_ids) > 0}
        class="sticky top-4 z-30 flex items-center justify-between gap-4 bg-primary/90 backdrop-blur-md text-primary-content px-8 py-4 rounded-3xl border border-primary/20 shadow-2xl animate-in slide-in-from-top-4"
      >
        <div class="flex flex-col">
          <span class="text-[10px] font-black uppercase opacity-70 text-white">
            Total Selecionado ({MapSet.size(@selected_ids)} itens)
          </span>
          <span class="text-2xl font-black text-white">{format_currency(@total_selected)}</span>
        </div>
        <div class="flex gap-2">
          <button phx-click="open_batch_linker" class="btn btn-white btn-md rounded-xl font-black">
            <.icon name="hero-link" class="size-4 mr-1" /> Vincular Recebimento
          </button>
          <button
            phx-click="clear_selection"
            class="btn btn-ghost btn-sm text-white/70 hover:text-white"
          >
            Cancelar
          </button>
        </div>
      </div>

      <.header>
        Gerenciamento de Reembolsos
        <:subtitle>Acompanhe despesas reembolsáveis e reconcilie com recebimentos.</:subtitle>
      </.header>
      
    <!-- Macro Summary -->
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="text-xs font-black uppercase opacity-40 mb-1">Total a Receber</h2>
            <p class="text-3xl font-black text-primary">{format_currency(@total_to_receive)}</p>
            <p class="text-[10px] opacity-50 font-bold uppercase mt-2">
              {@pending_count} pendentes + {@requested_count} solicitados
            </p>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="text-xs font-black uppercase opacity-40 mb-1">
              Solicitados (Aguardando Pagamento)
            </h2>
            <p class="text-3xl font-black text-info">{format_currency(@total_requested)}</p>
            <p class="text-[10px] opacity-50 font-bold uppercase mt-2">
              {@requested_count} solicitações enviadas
            </p>
          </div>
        </div>
      </div>
      
    <!-- PENDING/REQUESTED LIST -->
      <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
        <div class="card-body p-0">
          <div class="p-6 border-b border-base-200 flex justify-between items-center bg-base-200/10">
            <h2 class="text-sm font-black uppercase opacity-50">Lista de Despesas Reembolsáveis</h2>
            <div class="flex gap-2">
              <span class="badge badge-warning badge-xs text-[8px] uppercase">Pending</span>
              <span class="badge badge-info badge-xs text-[8px] uppercase">Requested</span>
              <span class="badge badge-success badge-xs text-[8px] uppercase">Paid</span>
            </div>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full text-xs">
              <thead class="bg-base-200/50">
                <tr>
                  <th class="w-12"></th>
                  <th>Data</th>
                  <th>Descrição</th>
                  <th>Conta</th>
                  <th>Status</th>
                  <th class="text-right">Valor</th>
                  <th class="text-center">Ações</th>
                </tr>
              </thead>
              <tbody>
                <%= for tx <- @all_reimbursable_list do %>
                  <tr class={["hover group", MapSet.member?(@selected_ids, tx.id) && "bg-primary/5"]}>
                    <td>
                      <input
                        type="checkbox"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={MapSet.member?(@selected_ids, tx.id)}
                        phx-click="toggle_selection"
                        phx-value-id={tx.id}
                      />
                    </td>
                    <td class="whitespace-nowrap font-medium">{format_date(tx.date)}</td>
                    <td class="font-bold max-w-xs truncate">{tx.description}</td>
                    <td class="opacity-60 uppercase font-bold text-[10px] whitespace-nowrap">
                      {tx.account.name}
                    </td>
                    <td>
                      <div class={[
                        "badge badge-xs uppercase font-black text-[8px]",
                        tx.reimbursement_status == "pending" && "badge-warning",
                        tx.reimbursement_status == "requested" && "badge-info"
                      ]}>
                        {translate_reimbursement_status(tx.reimbursement_status, tx.amount)}
                      </div>
                    </td>
                    <td class={[
                      "text-right font-black whitespace-nowrap",
                      if(Decimal.gt?(tx.amount, 0), do: "text-success", else: "text-error")
                    ]}>
                      {format_currency(tx.amount)}
                    </td>
                    <td class="text-center">
                      <div class="flex justify-center gap-1">
                        <button
                          phx-click="link_single_expense"
                          phx-value-id={tx.id}
                          class="btn btn-ghost btn-xs text-success"
                          title="Vincular Recebimento"
                        >
                          <.icon name="hero-link" class="size-4" />
                        </button>
                        <%= if tx.reimbursement_status == "pending" do %>
                          <button
                            phx-click="mark_requested"
                            phx-value-id={tx.id}
                            class="btn btn-ghost btn-xs text-info"
                            title="Marcar como Solicitado"
                          >
                            <.icon name="hero-paper-airplane" class="size-4" />
                          </button>
                        <% end %>
                        <%= if tx.reimbursement_status == "requested" do %>
                          <button
                            phx-click="mark_pending"
                            phx-value-id={tx.id}
                            class="btn btn-ghost btn-xs text-warning opacity-50 hover:opacity-100"
                            title="Reverter para Pendente"
                          >
                            <.icon name="hero-arrow-uturn-left" class="size-4" />
                          </button>
                        <% end %>
                        <button
                          phx-click="remove_reimbursable"
                          phx-value-id={tx.id}
                          class="btn btn-ghost btn-xs text-error opacity-30 hover:opacity-100"
                          title="Não é reembolsável"
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@all_reimbursable_list) do %>
                  <tr>
                    <td colspan="7" class="text-center py-20 opacity-30 italic text-sm">
                      Nenhuma despesa reembolsável encontrada.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      
    <!-- HISTORY -->
      <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
        <div class="card-body p-0">
          <div class="p-6 border-b border-base-200 bg-success/5">
            <h2 class="text-sm font-black uppercase text-success">
              Histórico de Reembolsos Concluídos
            </h2>
          </div>
          <div class="p-6 space-y-4">
            <%= if Enum.empty?(@paid_groups) do %>
              <p class="text-center py-10 opacity-30 italic text-sm">
                Nenhum reembolso concluído ainda.
              </p>
            <% end %>

            <%= for {link_key, txs} <- @paid_groups do %>
              <% credit = Enum.find(txs, &Decimal.gt?(&1.amount, 0))
              expenses = Enum.filter(txs, &Decimal.lt?(&1.amount, 0)) %>
              <div class="p-4 bg-base-200/50 rounded-2xl border border-base-300 flex flex-col md:flex-row gap-6 justify-between items-center group">
                <div class="flex-1 flex flex-col md:flex-row gap-6 items-center w-full">
                  <!-- Expenses Side -->
                  <div class="flex-1 space-y-1 w-full">
                    <p class="text-[8px] font-black uppercase opacity-40">Despesas Cobertas</p>
                    <%= for ex <- expenses do %>
                      <div class="flex justify-between items-center bg-base-100 p-2 rounded-lg border border-base-300/50">
                        <div class="flex flex-col">
                          <span class="text-[10px] font-bold truncate max-w-[150px]">
                            {ex.description}
                          </span>
                          <span class="text-[8px] opacity-50 uppercase font-black">
                            {format_date(ex.date)}
                          </span>
                        </div>
                        <span class="text-[10px] font-black text-error">
                          {format_currency(ex.amount)}
                        </span>
                      </div>
                    <% end %>
                  </div>

                  <div class="hidden md:block">
                    <.icon name="hero-arrow-long-right" class="size-6 opacity-20" />
                  </div>
                  
    <!-- Credit Side -->
                  <div class="flex-1 space-y-1 w-full">
                    <p class="text-[8px] font-black uppercase opacity-40">Recebimento</p>
                    <div
                      :if={credit}
                      class="flex justify-between items-center bg-success/10 p-2 rounded-lg border border-success/20"
                    >
                      <div class="flex flex-col">
                        <span class="text-[10px] font-black text-success truncate max-w-[150px]">
                          {credit.description}
                        </span>
                        <span class="text-[8px] text-success/60 font-black uppercase">
                          {format_date(credit.date)}
                        </span>
                      </div>
                      <span class="text-[10px] font-black text-success">
                        {format_currency(credit.amount)}
                      </span>
                    </div>
                    <p :if={!credit} class="text-[10px] text-warning italic">
                      Crédito não encontrado ou excluído.
                    </p>
                  </div>
                </div>

                <div class="flex flex-col items-end gap-2 border-t md:border-t-0 md:border-l border-base-300 pt-4 md:pt-0 md:pl-6">
                  <span class="text-[9px] font-black opacity-30 uppercase">
                    Link: {String.slice(link_key, 0..7)}
                  </span>
                  <button
                    phx-click="unlink_reimbursement"
                    phx-value-link-key={link_key}
                    class="btn btn-ghost btn-xs text-error opacity-0 group-hover:opacity-100 transition-opacity"
                  >
                    <.icon name="hero-link-slash" class="size-4 mr-1" /> Desvincular
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>

    <!-- Link Modal with Search -->
    <.modal :if={@show_linker_modal} id="linker-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2">
        <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-success">
          Vincular Recebimento
        </h2>

        <%!-- Expense being reimbursed --%>
        <div class="bg-base-200 rounded-xl p-3 mb-4 space-y-1">
          <%= for tx <- Enum.filter(@all_reimbursable_list, &MapSet.member?(@selected_ids, &1.id)) do %>
            <div class="flex items-center justify-between text-xs">
              <div>
                <span class="opacity-50 mr-2">{format_date(tx.date)}</span>
                <span class="font-semibold">{tx.description}</span>
              </div>
              <span class="font-mono text-error font-bold">{format_currency(tx.amount)}</span>
            </div>
          <% end %>
          <div class="border-t border-base-300 pt-1 mt-1 flex justify-between text-xs font-black">
            <span class="opacity-50 uppercase tracking-wider">Total de despesas</span>
            <span class="text-error">{format_currency(@total_selected)}</span>
          </div>
        </div>

        <%!-- Running total of selected credits --%>
        <div
          :if={MapSet.size(@selected_credit_ids) > 0}
          class="bg-success/10 border border-success/30 rounded-xl p-3 mb-4 flex items-center justify-between text-xs"
        >
          <span class="font-bold opacity-70">
            {MapSet.size(@selected_credit_ids)} crédito(s) selecionado(s)
          </span>
          <div class="text-right">
            <span class="font-black text-success">{format_currency(@total_credits_selected)}</span>
            <%= if Decimal.eq?(Decimal.round(@total_credits_selected, 2), Decimal.round(Decimal.abs(@total_selected), 2)) do %>
              <div class="text-[8px] text-success font-black uppercase">Match Perfeito!</div>
            <% end %>
          </div>
        </div>

        <p class="text-xs opacity-50 mb-4">Selecione um ou mais créditos que cubram esta despesa:</p>
        
    <!-- Search Field -->
        <div class="mb-4">
          <div class="relative">
            <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-30" />
            </div>
            <input
              type="text"
              placeholder="Buscar por descrição ou valor..."
              class="input input-bordered w-full pl-10 h-12 rounded-2xl bg-base-200 border-none focus:ring-success"
              phx-keyup="linker_search_change"
              phx-debounce="300"
              value={@linker_search}
            />
          </div>
        </div>

        <div class="space-y-2 max-h-72 overflow-y-auto pr-2 mb-4">
          <%= if Enum.empty?(@available_credits) do %>
            <div class="text-center py-10 opacity-40 italic">
              Nenhum crédito disponível encontrado.
            </div>
          <% end %>

          <%= for credit <- @available_credits do %>
            <button
              type="button"
              phx-click="toggle_credit"
              phx-value-credit-id={credit.id}
              class={[
                "w-full text-left flex items-center gap-3 p-3 border-2 rounded-xl hover:border-success hover:bg-success/5 transition-all",
                if(MapSet.member?(@selected_credit_ids, credit.id),
                  do: "border-success bg-success/5 shadow-sm shadow-success/10",
                  else: "border-base-300"
                )
              ]}
            >
              <div class={[
                "size-5 rounded-full border-2 flex items-center justify-center shrink-0 transition-all",
                if(MapSet.member?(@selected_credit_ids, credit.id),
                  do: "border-success bg-success",
                  else: "border-base-300"
                )
              ]}>
                <.icon
                  :if={MapSet.member?(@selected_credit_ids, credit.id)}
                  name="hero-check"
                  class="size-3 text-success-content"
                />
              </div>
              <div class="flex-1 min-w-0">
                <div class="text-[9px] font-bold uppercase opacity-50">
                  {format_date(credit.date)} — {credit.account.name}
                </div>
                <div class="font-black text-sm truncate">{credit.description}</div>
              </div>
              <span class="font-black text-success shrink-0">{format_currency(credit.amount)}</span>
            </button>
          <% end %>
        </div>

        <%!-- Confirm button --%>
        <button
          type="button"
          phx-click="confirm_link"
          disabled={MapSet.size(@selected_credit_ids) == 0}
          class="btn btn-success w-full rounded-2xl font-black disabled:opacity-30"
        >
          <.icon name="hero-link" class="size-4 mr-2" />
          Vincular {MapSet.size(@selected_credit_ids)} Crédito(s)
        </button>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:total_selected, Decimal.new("0"))
     |> assign(:show_linker_modal, false)
     |> assign(:linker_search, "")
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))
     |> fetch_data()}
  end

  @impl true
  def handle_event("toggle_selection", %{"id" => id}, socket) do
    new_selection =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    # Calculate total
    total =
      socket.assigns.all_reimbursable_list
      |> Enum.filter(&MapSet.member?(new_selection, &1.id))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
      |> Decimal.abs()

    {:noreply, socket |> assign(selected_ids: new_selection, total_selected: total)}
  end

  @impl true
  def handle_event("clear_selection", _, socket) do
    {:noreply, socket |> assign(selected_ids: MapSet.new(), total_selected: Decimal.new("0"))}
  end

  @impl true
  def handle_event("mark_requested", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: "requested"})
    {:noreply, fetch_data(socket)}
  end

  @impl true
  def handle_event("mark_pending", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: "pending"})
    {:noreply, fetch_data(socket)}
  end

  @impl true
  def handle_event("remove_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: nil})
    {:noreply, fetch_data(socket)}
  end

  @impl true
  def handle_event("link_single_expense", %{"id" => id}, socket) do
    new_selection = MapSet.new([id])

    total =
      socket.assigns.all_reimbursable_list
      |> Enum.filter(&(&1.id == id))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
      |> Decimal.abs()

    {:noreply,
     socket
     |> assign(selected_ids: new_selection, total_selected: total)
     |> assign(:show_linker_modal, true)
     |> assign(:linker_search, "")
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))
     |> update_linker_list()}
  end

  @impl true
  def handle_event("unlink_reimbursement", %{"link-key" => link_key}, socket) do
    Transactions.unlink_reimbursement_by_key(link_key)

    {:noreply,
     socket |> put_flash(:success, "Reembolso desvinculado com sucesso.") |> fetch_data()}
  end

  @impl true
  def handle_event("open_batch_linker", _, socket) do
    {:noreply,
     socket
     |> assign(:show_linker_modal, true)
     |> assign(:linker_search, "")
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))
     |> update_linker_list()}
  end

  @impl true
  def handle_event("linker_search_change", %{"value" => search}, socket) do
    {:noreply, socket |> assign(:linker_search, search) |> update_linker_list()}
  end

  @impl true
  def handle_event("toggle_credit", %{"credit-id" => credit_id}, socket) do
    selected = socket.assigns.selected_credit_ids

    new_selected =
      if MapSet.member?(selected, credit_id),
        do: MapSet.delete(selected, credit_id),
        else: MapSet.put(selected, credit_id)

    total =
      socket.assigns.available_credits
      |> Enum.filter(&MapSet.member?(new_selected, &1.id))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))

    {:noreply,
     socket
     |> assign(:selected_credit_ids, new_selected)
     |> assign(:total_credits_selected, total)}
  end

  @impl true
  def handle_event("confirm_link", _params, socket) do
    selected_expense_ids = socket.assigns.selected_ids
    selected_credit_ids = socket.assigns.selected_credit_ids
    link_key = Ecto.UUID.generate()

    expense =
      socket.assigns.all_reimbursable_list
      |> Enum.find(&MapSet.member?(selected_expense_ids, &1.id))

    cat_id = expense && expense.category_id

    Enum.each(selected_expense_ids, fn id ->
      tx = Transactions.get_transaction!(id)

      Transactions.update_transaction(tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key
      })
    end)

    Enum.each(selected_credit_ids, fn id ->
      tx = Transactions.get_transaction!(id)

      Transactions.update_transaction(tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: tx.category_id || cat_id
      })
    end)

    {:noreply,
     socket
     |> assign(:show_linker_modal, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:total_selected, Decimal.new("0"))
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))
     |> put_flash(
       :success,
       "#{MapSet.size(selected_credit_ids)} crédito(s) vinculado(s) à despesa!"
     )
     |> fetch_data()}
  end

  @impl true
  def handle_event("close_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_linker_modal, false)
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))}
  end

  defp fetch_data(socket) do
    pending = Transactions.list_all_transactions(%{"reimbursement_status" => "pending"})
    requested = Transactions.list_all_transactions(%{"reimbursement_status" => "requested"})
    paid = Transactions.list_all_transactions(%{"reimbursement_status" => "paid"})

    all_reimbursable = (pending ++ requested) |> Enum.sort_by(& &1.date, {:asc, Date})

    paid_groups =
      paid
      |> Enum.filter(& &1.reimbursement_link_key)
      |> Enum.group_by(& &1.reimbursement_link_key)

    total_pending =
      Enum.reduce(pending, Decimal.new("0"), &Decimal.add(&2, &1.amount)) |> Decimal.abs()

    total_requested =
      Enum.reduce(requested, Decimal.new("0"), &Decimal.add(&2, &1.amount)) |> Decimal.abs()

    total_to_receive = Decimal.add(total_pending, total_requested)

    total_recovered =
      Enum.reduce(paid, Decimal.new("0"), fn tx, acc ->
        if Decimal.gt?(tx.amount, 0), do: Decimal.add(acc, tx.amount), else: acc
      end)

    socket
    |> assign(:all_reimbursable_list, all_reimbursable)
    |> assign(:paid_groups, paid_groups)
    |> assign(:total_pending, total_pending)
    |> assign(:total_requested, total_requested)
    |> assign(:total_to_receive, total_to_receive)
    |> assign(:pending_count, length(pending))
    |> assign(:requested_count, length(requested))
    |> assign(:total_recovered_month, total_recovered)
  end

  defp update_linker_list(socket) do
    target_amount = socket.assigns.total_selected |> Decimal.round(2)
    search = String.downcase(socket.assigns.linker_search)

    expense_date =
      socket.assigns.all_reimbursable_list
      |> Enum.find(&MapSet.member?(socket.assigns.selected_ids, &1.id))
      |> then(&(&1 && &1.date))

    # Pass description search to DB; filter amount matches in memory
    desc_search = if Decimal.parse(search) == :error, do: search, else: ""
    all_credits = Transactions.list_reimbursement_credit_candidates(desc_search)

    filtered =
      if search == "" do
        all_credits
      else
        Enum.filter(all_credits, fn tx ->
          String.contains?(String.downcase(tx.description), search) ||
            String.contains?(Decimal.to_string(tx.amount), search)
        end)
      end

    sorted =
      filtered
      |> Enum.sort(fn a, b ->
        exact_a = Decimal.eq?(Decimal.round(a.amount, 2), target_amount)
        exact_b = Decimal.eq?(Decimal.round(b.amount, 2), target_amount)

        cond do
          exact_a != exact_b ->
            exact_a

          expense_date != nil ->
            diff_a = abs(Date.diff(a.date, expense_date))
            diff_b = abs(Date.diff(b.date, expense_date))
            diff_a <= diff_b

          true ->
            Date.compare(a.date, b.date) != :lt
        end
      end)
      |> Enum.take(30)

    assign(socket, :available_credits, sorted)
  end
end
