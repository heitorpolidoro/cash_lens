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

  @impl true
  def handle_event(
        "open_batch_link",
        %{"batch-account-id" => account_id, "batch-inserted-at" => inserted_at},
        socket
      ) do
    batch = find_orphan_batch(socket.assigns.orphan_batches, account_id, inserted_at)

    {:noreply,
     socket
     |> assign(:show_link_modal, true)
     |> assign(:link_origin_batch, batch)
     |> assign(:link_candidates, Transactions.list_credit_card_payment_candidates())}
  end

  @impl true
  def handle_event("link_batch", %{"payment-id" => payment_id}, socket) do
    batch = socket.assigns.link_origin_batch

    if batch do
      ids = Enum.map(batch.transactions, & &1.id)
      Transactions.link_credit_card_batch(ids, payment_id)
    end

    {:noreply,
     socket
     |> assign(:show_link_modal, false)
     |> assign(:link_origin_batch, nil)
     |> assign(:link_candidates, [])
     |> put_flash(:success, "Fatura vinculada!")
     |> load_data()}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_link_modal, false)
     |> assign(:link_origin_batch, nil)
     |> assign(:link_candidates, [])}
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

  defp find_orphan_batch(batches, account_id, inserted_at) do
    {:ok, parsed_inserted_at, _} = DateTime.from_iso8601(inserted_at)

    Enum.find(batches, fn batch ->
      to_string(batch.account_id) == account_id and
        DateTime.compare(batch.inserted_at, parsed_inserted_at) == :eq
    end)
  end

  defp load_data(socket) do
    socket
    |> assign(:page_title, "Cartão de Crédito")
    |> assign(:suggestions, Transactions.list_credit_card_link_suggestions())
    |> assign(:orphan_batches, Transactions.list_credit_card_orphan_batches())
    |> assign(:divergent, Transactions.list_credit_card_divergent_links())
    |> assign(:linked, Transactions.list_credit_card_linked())
    |> assign(
      :payments_without_children,
      Transactions.list_credit_card_payments_without_children()
    )
    |> assign_new(:show_link_modal, fn -> false end)
    |> assign_new(:link_origin_batch, fn -> nil end)
    |> assign_new(:link_candidates, fn -> [] end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-4xl mx-auto">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Cartão de Crédito</h1>
          <p class="text-xs opacity-50 mt-1">
            {length(@suggestions)} faturas para confirmar · {length(@divergent)} com divergência · {length(
              @payments_without_children
            )} sem fatura
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
              <td class="text-right">
                <button
                  class="btn btn-outline btn-primary btn-xs"
                  phx-click="open_batch_link"
                  phx-value-batch-account-id={batch.account_id}
                  phx-value-batch-inserted-at={DateTime.to_iso8601(batch.inserted_at)}
                >
                  <.icon name="hero-link" class="size-3" /> Vincular
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <div class="px-6 py-4 border-b border-base-300">
          <h2 class="font-black uppercase tracking-tight text-sm">Pagamentos sem Fatura</h2>
        </div>
        <div :if={@payments_without_children == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhum pagamento sem fatura vinculada.
        </div>
        <table :if={@payments_without_children != []} class="table table-sm w-full text-xs">
          <tbody>
            <tr :for={payment <- @payments_without_children} class="hover">
              <td class="font-mono opacity-60 whitespace-nowrap">
                {Calendar.strftime(payment.date, "%d/%m/%Y")}
              </td>
              <td>
                {payment.description}
                <span class="opacity-50">({payment.account && payment.account.name})</span>
              </td>
              <td class="text-right font-mono font-black">{format_currency(payment.amount)}</td>
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

      <.modal
        :if={@show_link_modal}
        id="batch-link-modal"
        show
        on_cancel={JS.push("close_modal")}
      >
        <div class="p-2">
          <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter text-primary">
            Vincular Fatura
          </h2>
          <p class="text-xs opacity-60 mb-6">
            Selecione o pagamento correspondente abaixo para este lote de {format_currency(
              @link_origin_batch && @link_origin_batch.total
            )}.
          </p>

          <div class="space-y-3 max-h-96 overflow-y-auto pr-2">
            <div :if={@link_candidates == []} class="text-center py-10 opacity-40 italic">
              Nenhum pagamento de Cartão de Crédito disponível para vincular.
            </div>
            <button
              :for={payment <- @link_candidates}
              type="button"
              phx-click="link_batch"
              phx-value-payment-id={payment.id}
              class="w-full text-left flex items-center justify-between p-3 border-2 border-base-300 rounded-xl hover:border-primary hover:bg-primary/5 transition-all group"
            >
              <div class="flex flex-col">
                <span class="text-[9px] font-bold uppercase opacity-50">
                  {Calendar.strftime(payment.date, "%d/%m/%Y")} — {payment.account &&
                    payment.account.name}
                </span>
                <span class="font-black text-md group-hover:text-primary">
                  {payment.description}
                </span>
              </div>
              <div class="text-right">
                <span class="font-black text-md">{format_currency(payment.amount)}</span>
              </div>
            </button>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
