defmodule CashLensWeb.TransactionLive.ReimbursementLinkComponent do
  use CashLensWeb, :live_component

  alias CashLens.Transactions

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal
        :if={@show}
        id={"#{@id}-modal"}
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-success">
            Vincular Reembolso
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Selecione abaixo a despesa que foi coberta por este recebimento de {format_currency(
              @reimbursement_credit.amount
            )}.
          </p>
          
    <!-- Campo de Busca -->
          <div class="mb-6">
            <div class="relative">
              <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                <.icon name="hero-magnifying-glass" class="size-4 opacity-30" />
              </div>
              <input
                type="text"
                placeholder="Buscar por descrição ou valor..."
                class="input input-bordered w-full pl-10 h-12 rounded-2xl bg-base-200 border-none focus:ring-success"
                phx-keyup="reimbursement_search_change"
                phx-target={@myself}
                phx-debounce="300"
                value={@reimbursement_search}
              />
            </div>
          </div>

          <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
            <%= if Enum.empty?(@pending_reimbursements) do %>
              <div class="text-center py-10 opacity-40 italic">
                Nenhuma despesa pendente de reembolso encontrada.
              </div>
            <% end %>
            <%= for pending <- @pending_reimbursements do %>
              <button
                type="button"
                phx-click="link_reimbursement"
                phx-target={@myself}
                phx-value-expense-id={pending.id}
                class={[
                  "w-full text-left flex items-center justify-between p-3 border-2 rounded-xl hover:border-success hover:bg-success/5 transition-all group",
                  if(
                    Decimal.eq?(
                      Decimal.abs(Decimal.round(pending.amount, 2)),
                      Decimal.round(@reimbursement_credit.amount, 2)
                    ),
                    do: "border-success bg-success/5 shadow-lg shadow-success/10",
                    else: "border-base-300"
                  )
                ]}
              >
                <div class="flex flex-col">
                  <span class="text-[9px] font-bold uppercase opacity-50">
                    {format_date(pending.date)} — {pending.account.name}
                  </span>
                  <span class="font-black text-md group-hover:text-success">
                    {pending.description}
                  </span>
                  <div
                    :if={is_nil(pending.category_id)}
                    class="text-[8px] text-warning font-black uppercase mt-0.5"
                  >
                    Sem Categoria
                  </div>
                </div>
                <div class="text-right">
                  <span class="font-black text-md text-error">{format_currency(pending.amount)}</span>
                  <div
                    :if={
                      Decimal.eq?(
                        Decimal.abs(Decimal.round(pending.amount, 2)),
                        Decimal.round(@reimbursement_credit.amount, 2)
                      )
                    }
                    class="text-[8px] text-success font-black uppercase mt-0.5"
                  >
                    Match Perfeito!
                  </div>
                </div>
              </button>
            <% end %>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:reimbursement_search, fn -> "" end)
      |> assign_new(:pending_reimbursements, fn -> [] end)

    socket =
      if assigns[:reimbursement_credit] do
        update_reimbursement_linker_list(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("reimbursement_search_change", %{"value" => search}, socket) do
    {:noreply,
     socket |> assign(:reimbursement_search, search) |> update_reimbursement_linker_list()}
  end

  @impl true
  def handle_event("link_reimbursement", %{"expense-id" => expense_id}, socket) do
    credit_tx = socket.assigns.reimbursement_credit
    expense_tx = Transactions.get_transaction!(expense_id)
    link_key = Ecto.UUID.generate()

    final_category_id = expense_tx.category_id || credit_tx.category_id

    {:ok, _} =
      Transactions.update_transaction(expense_tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: final_category_id
      })

    {:ok, _} =
      Transactions.update_transaction(credit_tx, %{
        reimbursement_status: "paid",
        reimbursement_link_key: link_key,
        category_id: final_category_id
      })

    send(self(), :reimbursement_linked)

    {:noreply, socket}
  end

  defp update_reimbursement_linker_list(socket) do
    credit_tx = socket.assigns.reimbursement_credit
    target_amount = credit_tx.amount |> Decimal.abs() |> Decimal.round(2)
    search = socket.assigns.reimbursement_search

    # 1. EXHAUSTIVE GLOBAL SEARCH for exact value matches
    exact_matches =
      Transactions.list_transactions(%{"amount" => Decimal.mult(target_amount, -1)}, 1, 100)
      |> Enum.filter(&is_nil(&1.reimbursement_link_key))

    # 2. CONTEXTUAL SEARCH (recent items or description match)
    filters = %{"amount_max" => -0.01}
    filters = if search != "", do: Map.put(filters, "search", search), else: filters
    recent_items = Transactions.list_transactions(filters, 1, 500)

    # Combine and deduplicate (by ID)
    all_pending =
      (exact_matches ++ recent_items)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(is_nil(&1.reimbursement_link_key) && &1.reimbursement_status != "paid"))

    sorted_pending =
      all_pending
      |> Enum.sort(fn a, b ->
        amount_a = Decimal.abs(a.amount) |> Decimal.round(2)
        amount_b = Decimal.abs(b.amount) |> Decimal.round(2)
        target = Decimal.round(target_amount, 2)

        exact_a = Decimal.eq?(amount_a, target)
        exact_b = Decimal.eq?(amount_b, target)
        pending_cat_a = is_nil(a.category_id)
        pending_cat_b = is_nil(b.category_id)

        cond do
          exact_a != exact_b -> exact_a
          pending_cat_a != pending_cat_b -> pending_cat_a
          true -> Date.compare(a.date, b.date) != :lt
        end
      end)
      |> Enum.take(50)

    assign(socket, :pending_reimbursements, sorted_pending)
  end
end
