defmodule CashLensWeb.CreditCardLinkLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Transactions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_data(socket)}
  end

  @impl true
  def handle_event(
        "confirm_suggestion",
        %{
          "payment-id" => payment_id,
          "batch-account-id" => account_id,
          "batch-inserted-at" => inserted_at
        },
        socket
      ) do
    batch = find_batch(socket.assigns.suggestions, payment_id, account_id, inserted_at)

    if batch do
      ids = Enum.map(batch.transactions, & &1.id)
      Transactions.link_credit_card_batch(ids, payment_id)
    end

    {:noreply, socket |> put_flash(:success, "Fatura vinculada!") |> load_data()}
  end

  @impl true
  def handle_event("unlink", %{"id" => parent_id}, socket) do
    Transactions.unlink_credit_card_children(parent_id)
    {:noreply, socket |> put_flash(:success, "Vínculo desfeito.") |> load_data()}
  end

  defp find_batch(collection, payment_id, account_id, inserted_at) do
    {:ok, parsed_inserted_at, _} = DateTime.from_iso8601(inserted_at)

    Enum.find_value(collection, fn {payment, batch} ->
      if (is_nil(payment_id) or payment.id == payment_id) and
           to_string(batch.account_id) == account_id and
           DateTime.compare(batch.inserted_at, parsed_inserted_at) == :eq,
         do: batch
    end)
  end

  defp load_data(socket) do
    socket
    |> assign(:page_title, "Cartão de Crédito")
    |> assign(:suggestions, Transactions.list_credit_card_link_suggestions())
    |> assign(:orphan_batches, Transactions.list_credit_card_orphan_batches())
    |> assign(:divergent, Transactions.list_credit_card_divergent_links())
    |> assign(:linked, Transactions.list_credit_card_linked())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-4xl mx-auto">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Cartão de Crédito</h1>
          <p class="text-xs opacity-50 mt-1">
            {length(@suggestions)} faturas para confirmar · {length(@divergent)} com divergência
          </p>
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Pares Sugeridos</h2>
        </div>
        <div :if={@suggestions == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Sem sugestões.
        </div>
        <table :if={@suggestions != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={{payment, batch} <- @suggestions} class="hover">
              <td class="font-mono opacity-60 whitespace-nowrap">
                {Calendar.strftime(payment.date, "%d/%m/%Y")}
              </td>
              <td>
                {payment.description}
                <span class="opacity-50">({payment.account && payment.account.name})</span>
              </td>
              <td class="text-right font-mono font-black">{format_currency(payment.amount)}</td>
              <td class="text-right">
                <button
                  class="btn btn-success btn-xs"
                  phx-click="confirm_suggestion"
                  phx-value-payment-id={payment.id}
                  phx-value-batch-account-id={batch.account_id}
                  phx-value-batch-inserted-at={DateTime.to_iso8601(batch.inserted_at)}
                >
                  <.icon name="hero-check" class="size-3" /> Confirmar
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Sem Pai Encontrado</h2>
        </div>
        <div :if={@orphan_batches == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma fatura órfã.
        </div>
        <table :if={@orphan_batches != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={batch <- @orphan_batches} class="hover">
              <td>{batch.account && batch.account.name}</td>
              <td>{length(batch.transactions)} transações</td>
              <td class="text-right font-mono font-black">{format_currency(batch.total)}</td>
              <td class="text-right opacity-40 text-[10px]">vínculo manual na edição da transação</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-error/40 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm text-error">
            Vinculados com Divergência
          </h2>
        </div>
        <div :if={@divergent == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma divergência.
        </div>
        <table :if={@divergent != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={%{parent: parent, children_total: total} <- @divergent} class="hover">
              <td>{parent.description}</td>
              <td class="text-right font-mono">{format_currency(parent.amount)}</td>
              <td class="text-right font-mono text-error">{format_currency(total)}</td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="unlink"
                  phx-value-id={parent.id}
                >
                  <.icon name="hero-link-slash" class="size-3" /> Desvincular
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Vinculados OK</h2>
        </div>
        <div :if={@linked == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma fatura vinculada ainda.
        </div>
        <table :if={@linked != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={%{parent: parent} <- @linked} class="hover">
              <td>{parent.description}</td>
              <td class="text-right font-mono font-black">{format_currency(parent.amount)}</td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="unlink"
                  phx-value-id={parent.id}
                >
                  <.icon name="hero-link-slash" class="size-3" /> Desvincular
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
