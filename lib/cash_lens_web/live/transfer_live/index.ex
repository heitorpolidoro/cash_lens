defmodule CashLensWeb.TransferLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLensWeb.TransactionLive.TransferLinkComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> assign(:transfer_origin, nil)
     |> assign(:pending_transfers, [])
     |> assign(:quick_transfer_form, to_form(%{}))
     |> assign(:accounts, Accounts.list_accounts())
     |> load_data()}
  end

  @impl true
  def handle_event("confirm_pair", %{"a" => id_a, "b" => id_b}, socket) do
    {:ok, _} = Transactions.link_transfer_pair(id_a, id_b)
    {:noreply, socket |> put_flash(:success, "Transferência vinculada!") |> load_data()}
  end

  @impl true
  def handle_event("confirm_all", _params, socket) do
    Enum.each(socket.assigns.suggestions, fn {a, b} ->
      Transactions.link_transfer_pair(a.id, b.id)
    end)

    count = length(socket.assigns.suggestions)

    {:noreply,
     socket |> put_flash(:success, "#{count} transferências vinculadas!") |> load_data()}
  end

  @impl true
  def handle_event("open_transfer_link", %{"id" => id}, socket) do
    origin_tx = Transactions.get_transaction!(id)
    target_amount = Decimal.mult(origin_tx.amount, -1)

    candidates =
      Transactions.list_transactions(%{"amount" => target_amount})
      |> Enum.filter(fn t ->
        is_nil(t.transfer_key) and t.id != origin_tx.id and t.account_id != origin_tx.account_id
      end)
      |> Enum.sort_by(fn t -> abs(Date.diff(t.date, origin_tx.date)) end)
      |> Enum.take(50)

    {:noreply,
     socket
     |> assign(:show_transfer_modal, true)
     |> assign(:transfer_origin, origin_tx)
     |> assign(:pending_transfers, candidates)}
  end

  @impl true
  def handle_event("unlink", %{"key" => key}, socket) do
    Transactions.unlink_transfer_pair(key)
    {:noreply, socket |> put_flash(:success, "Transferência desvinculada.") |> load_data()}
  end

  @impl true
  def handle_info(:close_transfer_modal, socket) do
    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)}
  end

  @impl true
  def handle_info({:transfer_linked, message}, socket) do
    {:noreply,
     socket
     |> assign(:show_transfer_modal, false)
     |> assign(:show_quick_transfer_modal, false)
     |> put_flash(:success, message)
     |> load_data()}
  end

  defp load_data(socket) do
    suggestions = Transactions.list_transfer_suggestions()
    unmatched = Transactions.list_unmatched_transfers_without_suggestion()
    linked = Transactions.list_linked_transfer_pairs()

    socket
    |> assign(:page_title, "Transferências")
    |> assign(:suggestions, suggestions)
    |> assign(:unmatched, unmatched)
    |> assign(:linked, linked)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={TransferLinkComponent}
      id="transfer-linker"
      show_transfer_modal={@show_transfer_modal}
      show_quick_transfer_modal={@show_quick_transfer_modal}
      transfer_origin={@transfer_origin}
      pending_transfers={@pending_transfers}
      accounts={@accounts}
      quick_transfer_form={@quick_transfer_form}
    />

    <div class="py-6 space-y-8 max-w-4xl mx-auto">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Transferências</h1>
          <p class="text-xs opacity-50 mt-1">
            {@suggestions |> length()} pares para confirmar · {@unmatched |> length()} sem par
          </p>
        </div>
        <button
          :if={@suggestions != []}
          phx-click="confirm_all"
          class="btn btn-primary btn-sm"
          data-confirm={"Confirmar todos os #{length(@suggestions)} pares?"}
        >
          <.icon name="hero-check-circle" class="size-4" /> Confirmar Todos
        </button>
      </div>

      <%!-- Suggestions --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-black uppercase tracking-tight text-sm">Pares Sugeridos</h2>
          <span class="text-xs opacity-50">{length(@suggestions)} prontos para confirmar</span>
        </div>

        <div :if={@suggestions == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Sem sugestões — todas as transferências estão vinculadas!
        </div>

        <table :if={@suggestions != []} class="table table-sm w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Data</th>
              <th>Saída</th>
              <th class="text-center">Valor</th>
              <th>Entrada</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for {tx_out, tx_in} <- @suggestions do %>
              <tr class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">
                  {Calendar.strftime(tx_out.date, "%d/%m/%Y")}
                </td>
                <td>
                  <div class="font-semibold truncate max-w-[160px]">{tx_out.description}</div>
                  <div class="opacity-50 text-[10px]">
                    {tx_out.account && "#{tx_out.account.bank} - #{tx_out.account.name}"}
                  </div>
                </td>
                <td class="text-center">
                  <div class="flex items-center justify-center gap-1">
                    <.icon name="hero-arrows-right-left" class="size-3 opacity-40" />
                    <span class="font-mono font-black">
                      {format_currency(Decimal.abs(tx_out.amount))}
                    </span>
                  </div>
                </td>
                <td>
                  <div class="font-semibold truncate max-w-[160px]">{tx_in.description}</div>
                  <div class="opacity-50 text-[10px]">
                    {tx_in.account && "#{tx_in.account.bank} - #{tx_in.account.name}"}
                  </div>
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-success btn-xs"
                    phx-click="confirm_pair"
                    phx-value-a={tx_out.id}
                    phx-value-b={tx_in.id}
                  >
                    <.icon name="hero-check" class="size-3" /> Confirmar
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Unmatched singles --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-black uppercase tracking-tight text-sm">Sem Par Encontrado</h2>
          <span class="text-xs opacity-50">{length(@unmatched)} transações</span>
        </div>

        <div :if={@unmatched == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma transferência sem par.
        </div>

        <table :if={@unmatched != []} class="table table-sm w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Data</th>
              <th>Descrição</th>
              <th>Conta</th>
              <th class="text-right">Valor</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for tx <- @unmatched do %>
              <tr class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">
                  {Calendar.strftime(tx.date, "%d/%m/%Y")}
                </td>
                <td class="truncate max-w-xs">{tx.description}</td>
                <td class="opacity-60">
                  {tx.account && "#{tx.account.bank} - #{tx.account.name}"}
                </td>
                <td class={[
                  "text-right font-mono font-black",
                  if(Decimal.lt?(tx.amount, Decimal.new("0")), do: "text-error", else: "text-success")
                ]}>
                  {format_currency(tx.amount)}
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-outline btn-xs"
                    phx-click="open_transfer_link"
                    phx-value-id={tx.id}
                  >
                    <.icon name="hero-link" class="size-3" /> Vincular
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Linked pairs --%>
      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-black uppercase tracking-tight text-sm">Transferências Vinculadas</h2>
          <span class="text-xs opacity-50">{length(@linked)} pares</span>
        </div>

        <div :if={@linked == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma transferência vinculada ainda.
        </div>

        <table :if={@linked != []} class="table table-sm w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th>Data</th>
              <th>Saída</th>
              <th class="text-center">Valor</th>
              <th>Entrada</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for {tx_out, tx_in} <- @linked do %>
              <tr class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">
                  {Calendar.strftime(tx_out.date, "%d/%m/%Y")}
                </td>
                <td>
                  <div class="font-semibold truncate max-w-[160px]">{tx_out.description}</div>
                  <div class="opacity-50 text-[10px]">
                    {tx_out.account && "#{tx_out.account.bank} - #{tx_out.account.name}"}
                  </div>
                </td>
                <td class="text-center">
                  <div class="flex items-center justify-center gap-1">
                    <.icon name="hero-arrows-right-left" class="size-3 opacity-40" />
                    <span class="font-mono font-black">
                      {format_currency(Decimal.abs(tx_out.amount))}
                    </span>
                  </div>
                </td>
                <td>
                  <div class="font-semibold truncate max-w-[160px]">{tx_in.description}</div>
                  <div class="opacity-50 text-[10px]">
                    {tx_in.account && "#{tx_in.account.bank} - #{tx_in.account.name}"}
                  </div>
                </td>
                <td class="text-right">
                  <button
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="unlink"
                    phx-value-key={tx_out.transfer_key}
                    data-confirm="Desvincular este par de transferência?"
                  >
                    <.icon name="hero-link-slash" class="size-3" /> Desvincular
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
