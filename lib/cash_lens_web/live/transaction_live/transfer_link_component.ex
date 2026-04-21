defmodule CashLensWeb.TransactionLive.TransferLinkComponent do
  use CashLensWeb, :live_component

  alias CashLens.Transactions
  alias CashLens.Categories

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <!-- Modal Vincular Transferência -->
      <.modal
        :if={@show_transfer_modal}
        id="transfer-modal"
        show
        on_cancel={JS.push("close_modal", target: @myself)}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Vincular Transferência
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Selecione abaixo o par correspondente para este lançamento de {format_currency(
              @transfer_origin.amount
            )}.
          </p>

          <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
            <%= if Enum.empty?(@pending_transfers) do %>
              <div class="text-center py-10 opacity-40 italic">
                Nenhum par correspondente encontrado para esta transferência.
              </div>
            <% end %>
            <%= for pending <- @pending_transfers do %>
              <button
                type="button"
                phx-click="link_transfer"
                phx-target={@myself}
                phx-value-pair-id={pending.id}
                class="w-full text-left flex items-center justify-between p-3 border-2 border-base-300 rounded-xl hover:border-primary hover:bg-primary/5 transition-all group"
              >
                <div class="flex flex-col">
                  <span class="text-[9px] font-bold uppercase opacity-50">
                    {format_date(pending.date)} — {pending.account.name}
                  </span>
                  <span class="font-black text-md group-hover:text-primary">
                    {pending.description}
                  </span>
                </div>
                <div class="text-right">
                  <span class={[
                    "font-black text-md",
                    if(Decimal.lt?(pending.amount, 0), do: "text-error", else: "text-success")
                  ]}>
                    {format_currency(pending.amount)}
                  </span>
                </div>
              </button>
            <% end %>
          </div>

          <div class="mt-6 pt-6 border-t border-base-300">
            <button
              type="button"
              phx-click="open_quick_transfer"
              phx-target={@myself}
              class="btn btn-outline btn-primary w-full rounded-2xl"
            >
              <.icon name="hero-plus-circle" class="size-4 mr-1" />
              Não encontrei o par, criar manualmente
            </button>
          </div>
        </div>
      </.modal>

      <!-- Modal Criar Par da Transferência -->
      <.modal
        :if={@show_quick_transfer_modal}
        id="quick-transfer-modal"
        show
        on_cancel={JS.push("close_modal", target: @myself)}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Criar Par da Transferência
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Confirme os dados abaixo para criar a transação correspondente na conta destino.
          </p>

          <.form
            :let={f}
            for={@quick_transfer_form}
            id="quick-transfer-form"
            phx-submit="save_quick_transfer"
            phx-target={@myself}
            class="space-y-6"
          >
            <div class="grid grid-cols-2 gap-4">
              <.input field={f[:date]} type="date" label="Data" required readonly class="bg-base-200" />
              <.input
                field={f[:amount]}
                type="number"
                label="Valor"
                step="0.01"
                required
                readonly
                class="bg-base-200 font-bold"
              />
            </div>

            <.input
              field={f[:description]}
              type="text"
              label="Descrição"
              required
              placeholder="Ex: Transferência entre contas..."
            />

            <div class="form-control w-full">
              <label class="label">
                <span class="label-text font-bold text-primary">Conta Destino</span>
              </label>
              <select
                name="account_id"
                class="select select-bordered w-full rounded-2xl h-12"
                required
              >
                <option value="">Selecione a conta que recebeu/enviou</option>
                <%= for account <- Enum.reject(@accounts, & &1.id == @transfer_origin.account_id) do %>
                  <option value={account.id}>{account.name}</option>
                <% end %>
              </select>
            </div>

            <div class="pt-2">
              <.button phx-disable-with="Criando e vinculando..." variant="primary" class="w-full">
                Confirmar e Vincular
              </.button>
            </div>
          </.form>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    send(self(), :close_transfer_modal)
    {:noreply, socket}
  end

  @impl true
  def handle_event("link_transfer", %{"pair-id" => pair_id}, socket) do
    origin_tx = socket.assigns.transfer_origin
    pair_tx = Transactions.get_transaction!(pair_id)
    transfer_key = Ecto.UUID.generate()

    # Update both transactions with the same key
    {:ok, _} = Transactions.update_transaction(origin_tx, %{transfer_key: transfer_key})
    {:ok, _} = Transactions.update_transaction(pair_tx, %{transfer_key: transfer_key})

    send(self(), {:transfer_linked, "Transferência vinculada com sucesso!"})

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_quick_transfer", _params, socket) do
    origin = socket.assigns.transfer_origin

    form_data = %{
      "date" => origin.date,
      "amount" => Decimal.mult(origin.amount, -1),
      "description" => origin.description
    }

    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, true)
     |> assign(:quick_transfer_form, to_form(form_data))}
  end

  @impl true
  def handle_event(
        "save_quick_transfer",
        %{
          "account_id" => target_account_id,
          "description" => description,
          "date" => date,
          "amount" => amount
        },
        socket
      ) do
    origin_tx = socket.assigns.transfer_origin
    transfer_key = Ecto.UUID.generate()

    # 1. Update origin transaction
    {:ok, origin_tx} = Transactions.update_transaction(origin_tx, %{transfer_key: transfer_key})

    # 2. Create target transaction
    transfer_category = Categories.get_category_by_slug("transfer")

    {:ok, pair_tx} =
      Transactions.create_transaction(%{
        account_id: target_account_id,
        category_id: transfer_category.id,
        description: description,
        date: date,
        amount: amount,
        transfer_key: transfer_key
      })

    # 3. Recalculate balances
    CashLens.Accounting.calculate_monthly_balance(
      origin_tx.account_id,
      origin_tx.date.year,
      origin_tx.date.month
    )

    CashLens.Accounting.calculate_monthly_balance(
      pair_tx.account_id,
      pair_tx.date.year,
      pair_tx.date.month
    )

    send(self(), {:transfer_linked, "Par da transferência criado e vinculado!"})

    {:noreply, socket}
  end
end
