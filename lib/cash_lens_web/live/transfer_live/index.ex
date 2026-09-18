defmodule CashLensWeb.TransferLive.Index do
  @moduledoc """
  Transfers Center: reconciles movements between the user's own accounts.

  The page is a two-tab reconciliation panel — transfers still waiting for a
  counterpart, and the already reconciled history — fed by the automatic pairing
  suggestions from the `Transactions` context.
  """
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Transactions

  @tabs ~w(pending history)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transferências")
     |> assign(:tab, "pending")
     |> assign(:link_origin, nil)
     |> assign(:link_candidates, [])
     |> assign(:mirror_origin, nil)
     |> assign(:mirror_form, to_form(%{}))
     |> assign(:accounts, Accounts.list_active_accounts())
     |> load_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, normalize_tab(params["tab"]))}
  end

  defp normalize_tab(tab) when tab in @tabs, do: tab
  defp normalize_tab(_), do: "pending"

  @impl true
  def handle_event("confirm_pair", %{"a" => id_a, "b" => id_b}, socket) do
    {:ok, _} = Transactions.link_transfer_pair(id_a, id_b)
    {:noreply, socket |> put_flash(:success, "Transferência vinculada!") |> load_data()}
  end

  @impl true
  def handle_event("confirm_all", _params, socket) do
    Enum.each(socket.assigns.suggestions, fn {out, inc} ->
      Transactions.link_transfer_pair(out.id, inc.id)
    end)

    count = length(socket.assigns.suggestions)

    {:noreply,
     socket |> put_flash(:success, "#{count} transferências vinculadas!") |> load_data()}
  end

  @impl true
  def handle_event("open_link_modal", %{"id" => id}, socket) do
    origin = Transactions.get_transaction!(id)

    {:noreply,
     socket
     |> assign(:link_origin, origin)
     |> assign(:link_candidates, Transactions.list_transfer_link_candidates(origin))}
  end

  @impl true
  def handle_event("link_candidate", %{"id" => candidate_id}, socket) do
    {:ok, _} = Transactions.link_transfer_pair(socket.assigns.link_origin.id, candidate_id)

    {:noreply,
     socket
     |> close_modals()
     |> put_flash(:success, "Transferência vinculada!")
     |> load_data()}
  end

  @impl true
  def handle_event("open_mirror_modal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:mirror_origin, Transactions.get_transaction!(id))
     |> assign(:mirror_form, to_form(%{}))}
  end

  @impl true
  def handle_event("create_mirror", %{"account_id" => account_id}, socket) do
    case Transactions.create_mirror_transaction(socket.assigns.mirror_origin.id, account_id) do
      {:ok, _mirror} ->
        {:noreply,
         socket
         |> close_modals()
         |> put_flash(:success, "Transação espelho criada e vinculada!")
         |> load_data()}

      {:error, reason} ->
        {:noreply, socket |> close_modals() |> put_flash(:error, mirror_error_message(reason))}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modals(socket)}
  end

  @impl true
  def handle_event("unlink", %{"key" => key}, socket) do
    Transactions.unlink_transfer_pair(key)
    {:noreply, socket |> put_flash(:success, "Transferência desvinculada.") |> load_data()}
  end

  defp mirror_error_message(:same_account),
    do: "Não é possível criar o espelho na mesma conta da transação original."

  defp mirror_error_message(:already_linked),
    do: "Esta transação já faz parte de um par conciliado."

  defp mirror_error_message(_), do: "Não foi possível criar a transação espelho."

  defp close_modals(socket) do
    socket
    |> assign(:link_origin, nil)
    |> assign(:link_candidates, [])
    |> assign(:mirror_origin, nil)
  end

  defp load_data(socket) do
    suggestions = Transactions.list_transfer_suggestions()
    unmatched = Transactions.list_unmatched_transfers_without_suggestion(suggestions)

    socket
    |> assign(:suggestions, suggestions)
    |> assign(:unmatched, unmatched)
    |> assign(:linked, Transactions.list_linked_transfer_pairs())
    |> assign(:pending_count, length(suggestions) * 2 + length(unmatched))
  end

  defp account_name(nil), do: "-"
  defp account_name(account), do: "#{account.bank} - #{account.name}"

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6 max-w-5xl mx-auto">
      <div
        id="transfers-header"
        class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-4 border-b border-base-300"
      >
        <div>
          <h1 class="text-2xl font-black tracking-tight">Central de Transferências</h1>
          <p class="text-xs opacity-50 mt-1">
            Concilie movimentações entre suas contas próprias para anular a dupla contagem contábil.
          </p>
        </div>
        <.link navigate={~p"/admin/transfer_rules"} class="btn btn-outline btn-sm">
          <.icon name="hero-cog-6-tooth" class="size-4" /> Regras de Transferência
        </.link>
      </div>

      <div id="pending-pairs-card" class="bg-base-100 rounded-2xl p-5 border border-warning/40">
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs font-bold uppercase tracking-wider text-warning">
            Pares Pendentes
          </span>
          <span :if={@pending_count > 0} class="badge badge-warning badge-outline badge-sm">
            Ação Necessária
          </span>
        </div>
        <div class="text-2xl font-black text-warning">
          {pluralize(@pending_count, "transação", "transações")}
        </div>
        <p class="text-xs opacity-50 mt-1">
          Débitos ou créditos sem a contrapartida confirmada
        </p>
      </div>

      <div
        :if={@suggestions != []}
        id="transfer-suggestions"
        class="bg-primary/5 border border-primary/30 rounded-2xl p-5 space-y-4"
      >
        <div class="flex items-center justify-between gap-4">
          <div>
            <h2 class="text-sm font-black">
              Pares Sugeridos pelo Algoritmo ({pluralize(
                length(@suggestions),
                "par encontrado",
                "pares encontrados"
              )})
            </h2>
            <p class="text-xs opacity-50">
              Saídas e entradas de mesmo valor identificadas em datas próximas.
            </p>
          </div>
          <button
            phx-click="confirm_all"
            class="btn btn-primary btn-sm"
            data-confirm={"Confirmar todos os #{length(@suggestions)} pares?"}
          >
            Confirmar Todos
          </button>
        </div>

        <div class="space-y-2.5">
          <div
            :for={{tx_out, tx_in} <- @suggestions}
            id={"suggestion-#{tx_out.id}"}
            class="bg-base-100 p-4 rounded-xl border border-primary/20 flex flex-col md:flex-row md:items-center justify-between gap-4 text-xs"
          >
            <div class="flex flex-wrap items-center gap-3">
              <div>
                <span class="font-bold block">{account_name(tx_out.account)}</span>
                <span class="opacity-50">
                  {format_date(tx_out.date)} · {tx_out.description}
                </span>
              </div>
              <span class="font-mono font-bold text-error">
                {format_currency(tx_out.amount)}
              </span>
              <span class="text-primary font-black">➔</span>
              <div>
                <span class="font-bold block">{account_name(tx_in.account)}</span>
                <span class="opacity-50">
                  {format_date(tx_in.date)} · {tx_in.description}
                </span>
              </div>
              <span class="font-mono font-bold text-success">
                {format_currency(tx_in.amount)}
              </span>
            </div>
            <button
              class="btn btn-primary btn-xs"
              phx-click="confirm_pair"
              phx-value-a={tx_out.id}
              phx-value-b={tx_in.id}
            >
              Confirmar Par
            </button>
          </div>
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl border border-base-300 overflow-hidden">
        <div class="flex items-center border-b border-base-300 px-6 pt-3 gap-6 text-xs font-bold">
          <.link
            id="tab-pending"
            patch={~p"/transfers?tab=pending"}
            class={["pb-3 border-b-2", tab_class(@tab == "pending")]}
          >
            Pendentes de Pareamento ({@pending_count})
          </.link>
          <.link
            id="tab-history"
            patch={~p"/transfers?tab=history"}
            class={["pb-3 border-b-2", tab_class(@tab == "history")]}
          >
            Histórico Conciliado ({length(@linked)})
          </.link>
        </div>

        <div :if={@tab == "pending"} class="p-2">
          <div
            :if={@unmatched == [] and @suggestions == []}
            class="px-6 py-12 text-center opacity-40 text-sm"
          >
            Nenhuma transferência pendente de pareamento.
          </div>

          <table :if={@unmatched != []} id="pending-transfers" class="table table-sm w-full text-xs">
            <thead class="bg-base-200/50">
              <tr>
                <th>Data</th>
                <th>Conta</th>
                <th>Descrição</th>
                <th class="text-right">Valor</th>
                <th class="text-right">Ação</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={tx <- @unmatched} id={"pending-#{tx.id}"} class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">{format_date(tx.date)}</td>
                <td class="font-bold">{account_name(tx.account)}</td>
                <td class="truncate max-w-xs">{tx.description}</td>
                <td class={[
                  "text-right font-mono font-black",
                  if(Decimal.negative?(tx.amount), do: "text-error", else: "text-success")
                ]}>
                  {format_currency(tx.amount)}
                </td>
                <td class="text-right">
                  <div class="flex items-center justify-end gap-2">
                    <button
                      class="btn btn-outline btn-xs"
                      phx-click="open_link_modal"
                      phx-value-id={tx.id}
                    >
                      Vincular Manualmente
                    </button>
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="open_mirror_modal"
                      phx-value-id={tx.id}
                      title="Criar a transação correspondente na conta de destino"
                    >
                      + Criar Espelho
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@tab == "history"} class="p-2">
          <div :if={@linked == []} class="px-6 py-12 text-center opacity-40 text-sm">
            Nenhuma transferência conciliada ainda.
          </div>

          <table :if={@linked != []} id="reconciled-transfers" class="table table-sm w-full text-xs">
            <thead class="bg-base-200/50">
              <tr>
                <th>Data</th>
                <th>Fluxo de Transferência</th>
                <th class="text-right">Valor Conciliado</th>
                <th class="text-right">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{tx_out, tx_in} <- @linked} id={"linked-#{tx_out.id}"} class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">{format_date(tx_out.date)}</td>
                <td>
                  <div class="flex items-center gap-2">
                    <span class="font-bold">{account_name(tx_out.account)}</span>
                    <span class="text-primary font-bold">➔</span>
                    <span class="font-bold">{account_name(tx_in.account)}</span>
                  </div>
                </td>
                <td class="text-right font-mono font-black">
                  {format_currency(Decimal.abs(tx_out.amount))}
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
            </tbody>
          </table>
        </div>
      </div>

      <.modal :if={@link_origin} id="manual-link-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <h2 class="text-xl font-black mb-1">Vincular Manualmente</h2>
          <p class="text-xs opacity-60 mb-6">
            {format_date(@link_origin.date)} · {@link_origin.description} ·
            <span class="font-mono font-bold">{format_currency(@link_origin.amount)}</span>
          </p>

          <div :if={@link_candidates == []} class="text-center py-10 opacity-40 italic text-sm">
            Nenhum candidato encontrado para esta transferência.
          </div>

          <div class="space-y-2 max-h-96 overflow-y-auto pr-2">
            <button
              :for={candidate <- @link_candidates}
              type="button"
              phx-click="link_candidate"
              phx-value-id={candidate.transaction.id}
              class="w-full text-left flex items-center justify-between gap-4 p-3 border border-base-300 rounded-xl hover:border-primary hover:bg-primary/5 transition-all text-xs"
            >
              <div class="flex flex-col">
                <span class="font-bold">{candidate.transaction.description}</span>
                <span class="opacity-50">
                  {format_date(candidate.transaction.date)} · {account_name(
                    candidate.transaction.account
                  )}
                </span>
              </div>
              <div class="text-right whitespace-nowrap">
                <span class="font-mono font-black block">
                  {format_currency(candidate.transaction.amount)}
                </span>
                <span class="opacity-60">
                  Δ {format_currency(candidate.amount_diff)} · {pluralize(
                    candidate.day_diff,
                    "dia",
                    "dias"
                  )}
                </span>
              </div>
            </button>
          </div>
        </div>
      </.modal>

      <.modal :if={@mirror_origin} id="mirror-modal" show on_cancel={JS.push("close_modal")}>
        <div class="p-2">
          <h2 class="text-xl font-black mb-1">Criar Transação Espelho</h2>
          <p class="text-xs opacity-60 mb-6">
            Cria a contrapartida de {format_currency(Decimal.negate(@mirror_origin.amount))} na conta
            de destino e vincula as duas transações.
          </p>

          <.form for={@mirror_form} id="mirror-form" phx-submit="create_mirror" class="space-y-6">
            <div class="form-control w-full">
              <label class="label" for="mirror-account-id">
                <span class="label-text font-bold">Conta de Destino</span>
              </label>
              <select
                id="mirror-account-id"
                name="account_id"
                class="select select-bordered w-full"
                required
              >
                <option value="">Selecione a conta de destino</option>
                <option
                  :for={account <- Enum.reject(@accounts, &(&1.id == @mirror_origin.account_id))}
                  value={account.id}
                >
                  {account_label(account)}
                </option>
              </select>
            </div>

            <.button phx-disable-with="Criando..." variant="primary" class="w-full">
              Criar e Vincular
            </.button>
          </.form>
        </div>
      </.modal>
    </div>
    """
  end

  defp tab_class(true), do: "border-primary text-primary"
  defp tab_class(false), do: "border-transparent opacity-60 hover:opacity-100"
end
