defmodule CashLensWeb.CreditCardStatementLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.CreditCards

  @unpaid [:open, :closed]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Faturas de Cartão")
     |> assign(:selected, nil)
     |> assign(:suggestion, nil)
     |> assign(:candidates, [])
     |> load_statements()}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, assign_detail(socket, id)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
     |> assign(:suggestion, nil)
     |> assign(:candidates, [])}
  end

  @impl true
  def handle_event("link", %{"payment-id" => payment_id} = params, socket) do
    statement = target_statement(socket, params)

    case CreditCards.link_payment(statement, payment_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Fatura vinculada!")
         |> load_statements()
         |> reload_selected()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não foi possível vincular a fatura.")}
    end
  end

  @impl true
  def handle_event("unlink", _params, socket) do
    statement = socket.assigns.selected.statement

    case CreditCards.unlink_payment(statement) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Vínculo desfeito.")
         |> load_statements()
         |> reload_selected()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não foi possível desvincular a fatura.")}
    end
  end

  defp target_statement(_socket, %{"statement-id" => id}), do: CreditCards.get_statement!(id)
  defp target_statement(socket, _params), do: socket.assigns.selected.statement

  defp reload_selected(socket) do
    case socket.assigns.selected do
      nil -> socket
      %{statement: statement} -> assign_detail(socket, statement.id)
    end
  end

  defp assign_detail(socket, id) do
    detail = CreditCards.get_statement_detail(id)

    {suggestion, candidates} =
      if detail.lifecycle in @unpaid do
        candidates = CreditCards.payment_candidates(detail.statement)
        {List.first(candidates), candidates}
      else
        {nil, []}
      end

    socket
    |> assign(:selected, detail)
    |> assign(:suggestion, suggestion)
    |> assign(:candidates, candidates)
  end

  defp load_statements(socket) do
    entries = CreditCards.list_statements()
    card_groups = CreditCards.group_by_card(entries)

    socket
    |> assign(:card_groups, card_groups)
    |> assign(:metrics, CreditCards.hub_metrics(entries))
    |> assign(:suggestions, current_suggestions(card_groups))
  end

  # The one-click reconcile block is offered for the cycle currently shown on
  # each card, which is the only statement the operator can act on from the
  # overview. Older closed cycles are reconciled from their detail view.
  defp current_suggestions(card_groups) do
    card_groups
    |> Enum.filter(&(&1.current.lifecycle == :closed))
    |> Enum.map(&{&1.current.statement.id, CreditCards.suggest_payment(&1.current.statement)})
    |> Enum.reject(fn {_id, suggestion} -> is_nil(suggestion) end)
    |> Map.new()
  end

  defp lifecycle_badge(:open), do: {"badge-info", "Aberta (Em Curso)"}
  defp lifecycle_badge(:closed), do: {"badge-warning", "Fechada (Aguardando Pagamento)"}
  defp lifecycle_badge(:paid), do: {"badge-success", "Paga e Conciliada"}
  defp lifecycle_badge(:absorbed), do: {"badge-ghost", "Incorporada"}

  defp due_label(0), do: "hoje"
  defp due_label(1), do: "em 1 dia"
  defp due_label(days) when days < 0, do: "vencida há #{abs(days)} dias"
  defp due_label(days), do: "em #{days} dias"

  defp statement_count_label(1), do: "1 fatura"
  defp statement_count_label(count), do: "#{count} faturas"

  defp installment_label(%{installment_number: nil}), do: nil
  defp installment_label(%{installment_group: nil}), do: nil

  defp installment_label(%{installment_number: number, installment_group: group}),
    do: "Parcela #{number}/#{group.installments}"

  defp installment_label(_transaction), do: nil

  attr :lifecycle, :atom, required: true

  defp badge(assigns) do
    {class, label} = lifecycle_badge(assigns.lifecycle)
    assigns = assigns |> assign(:class, class) |> assign(:label, label)

    ~H"""
    <span class={"badge #{@class} badge-sm font-bold"}>{@label}</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6 max-w-5xl mx-auto">
      <div :if={is_nil(@selected)} class="space-y-6">
        <div>
          <h1 class="text-2xl font-black uppercase tracking-tight">Faturas de Cartão de Crédito</h1>
          <p class="text-xs opacity-50 mt-1">
            Acompanhe faturas abertas, fechadas e a conciliação com os débitos de pagamento em conta.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="bg-base-100 rounded-2xl p-5 border border-base-300 shadow-sm">
            <span class="text-xs font-bold uppercase tracking-wider opacity-50 block mb-1">
              Total a Pagar ({month_name(Date.utc_today().month)})
            </span>
            <div class="text-2xl font-black font-mono">{format_currency(@metrics.total_due)}</div>
            <p class="text-xs opacity-50 mt-1">Soma de faturas fechadas aguardando quitação</p>
          </div>

          <div class="bg-base-100 rounded-2xl p-5 border border-warning/40 shadow-sm">
            <span class="text-xs font-bold uppercase tracking-wider text-warning block mb-1">
              Faturas Aguardando Baixa
            </span>
            <div class="text-2xl font-black text-warning">
              {statement_count_label(@metrics.awaiting_count)}
            </div>
            <p class="text-xs opacity-50 mt-1">Faturas fechadas prontas para conciliar pagamento</p>
          </div>

          <div class="bg-base-100 rounded-2xl p-5 border border-info/40 shadow-sm">
            <span class="text-xs font-bold uppercase tracking-wider text-info block mb-1">
              Próximo Vencimento
            </span>
            <div :if={@metrics.next_due} class="text-2xl font-black text-info">
              {format_date(@metrics.next_due.due_date)} ({due_label(@metrics.next_due.days_remaining)})
            </div>
            <p :if={@metrics.next_due} class="text-xs opacity-50 mt-1">
              {@metrics.next_due.account_name} · {format_currency(@metrics.next_due.amount)}
            </p>
            <div :if={is_nil(@metrics.next_due)} class="text-sm opacity-40 italic mt-2">
              Nenhuma fatura fechada a vencer.
            </div>
          </div>
        </div>

        <div :if={@card_groups == []} class="px-6 py-12 text-center opacity-40 text-sm">
          Nenhuma fatura encontrada.
        </div>

        <div class="space-y-4">
          <div
            :for={group <- @card_groups}
            class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-6 space-y-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-200 pb-4">
              <div>
                <h2 class="font-black text-base">{group.account.name}</h2>
                <p class="text-xs opacity-40">
                  {group.account.bank}
                  <span :if={group.account.closing_day && group.account.due_day}>
                    · Fechamento dia {group.account.closing_day} · Vencimento dia {group.account.due_day}
                  </span>
                </p>
              </div>
              <.badge lifecycle={group.current.lifecycle} />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-4 gap-4 text-xs">
              <div>
                <span class="opacity-40 block font-semibold">Competência</span>
                <span class="font-bold text-sm">
                  {format_competencia(group.current.statement.competencia)}
                </span>
              </div>
              <div>
                <span class="opacity-40 block font-semibold">Vencimento</span>
                <span class="font-bold text-sm">
                  {format_date(group.current.statement.due_date)}
                  <span :if={is_nil(group.current.statement.due_date)}>Sem vencimento</span>
                </span>
              </div>
              <div>
                <span class="opacity-40 block font-semibold">
                  {if group.current.lifecycle == :open, do: "Total Parcial", else: "Total da Fatura"}
                </span>
                <span class="font-mono font-black text-base">
                  {format_currency(group.current.amount)}
                </span>
              </div>
              <div class="flex items-center sm:justify-end">
                <.link
                  patch={~p"/statements?id=#{group.current.statement.id}"}
                  class="btn btn-sm btn-ghost"
                >
                  Ver {group.current.line_count} lançamentos do ciclo
                </.link>
              </div>
            </div>

            <div
              :if={@suggestions[group.current.statement.id]}
              id={"reconcile-#{group.current.statement.id}"}
              class="rounded-xl bg-warning/10 border border-warning/40 p-4 flex flex-wrap items-center justify-between gap-3"
            >
              <div>
                <p class="text-sm font-bold">Pagamento Detectado no Extrato Bancário!</p>
                <p class="text-xs opacity-70">
                  {@suggestions[group.current.statement.id].description} · {format_date(
                    @suggestions[group.current.statement.id].date
                  )} · {@suggestions[group.current.statement.id].account &&
                    @suggestions[group.current.statement.id].account.name} ·
                  <span class="font-mono font-bold">
                    {format_currency(@suggestions[group.current.statement.id].amount)}
                  </span>
                </p>
              </div>
              <button
                class="btn btn-warning btn-sm"
                phx-click="link"
                phx-value-payment-id={@suggestions[group.current.statement.id].id}
                phx-value-statement-id={group.current.statement.id}
              >
                <.icon name="hero-link" class="size-4" /> Conciliar Pagamento em 1 Clique
              </button>
            </div>

            <div
              :if={
                group.current.lifecycle == :closed and
                  is_nil(@suggestions[group.current.statement.id])
              }
              class="border-t border-base-200 pt-3 flex flex-wrap items-center justify-between gap-2"
            >
              <p class="text-xs opacity-50 italic">
                Nenhum débito bancário compatível encontrado — a fatura segue como Fechada.
              </p>
              <.link
                patch={~p"/statements?id=#{group.current.statement.id}"}
                class="btn btn-outline btn-xs"
              >
                Vincular pagamento manualmente
              </.link>
            </div>

            <details :if={group.history != []} class="border-t border-base-200 pt-3">
              <summary class="text-xs font-bold opacity-60 cursor-pointer">
                Histórico por competência ({statement_count_label(length(group.history))})
              </summary>
              <div class="mt-3 divide-y divide-base-200 text-xs">
                <.link
                  :for={entry <- group.history}
                  patch={~p"/statements?id=#{entry.statement.id}"}
                  class="py-2 px-2 flex flex-wrap items-center justify-between gap-2 hover:bg-base-200 rounded-lg"
                >
                  <span class="font-semibold">
                    {format_competencia(entry.statement.competencia)}
                  </span>
                  <span class="opacity-40">
                    {if entry.statement.due_date,
                      do: "Venceu #{format_date(entry.statement.due_date)}",
                      else: "Sem vencimento"}
                  </span>
                  <span class="font-mono font-bold">{format_currency(entry.amount)}</span>
                  <.badge lifecycle={entry.lifecycle} />
                </.link>
              </div>
            </details>
          </div>
        </div>
      </div>

      <div :if={@selected} class="space-y-6">
        <div class="flex items-center justify-between">
          <.link patch={~p"/statements"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Voltar
          </.link>
        </div>

        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
          <div class="px-6 py-4 border-b border-base-300 flex flex-wrap items-start justify-between gap-3">
            <div>
              <h1 class="text-xl font-black uppercase tracking-tight">
                {@selected.account && @selected.account.name}
              </h1>
              <p class="text-xs opacity-60 mt-1">
                Competência {format_competencia(@selected.statement.competencia)}<span :if={
                  @selected.statement.due_date
                }>· Vence em {format_date(@selected.statement.due_date)}</span>
              </p>
              <p class="text-[10px] opacity-40 mt-1">{@selected.statement.source_file}</p>
              <div class="mt-2"><.badge lifecycle={@selected.lifecycle} /></div>
            </div>
            <div class="text-right">
              <p class="text-2xl font-black font-mono">{format_currency(@selected.amount)}</p>
              <p class="text-[10px] opacity-50 mt-1">
                Soma dos lançamentos: {format_currency(@selected.line_total)}
              </p>
            </div>
          </div>

          <div
            :if={@selected.lifecycle == :paid}
            class={[
              "px-6 py-4 flex flex-wrap items-center justify-between gap-3",
              if(@selected.status == :divergent, do: "bg-error/10", else: "bg-success/10")
            ]}
          >
            <div>
              <p class="text-xs font-bold uppercase opacity-60">
                Pagamento vinculado
                <span :if={@selected.status == :divergent} class="text-error">
                  · valor divergente da fatura
                </span>
              </p>
              <p class="font-black">
                {@selected.payment && @selected.payment.description}
                <span class="opacity-50 font-normal">
                  ({@selected.payment && format_date(@selected.payment.date)} · {@selected.payment &&
                    (@selected.payment.account && @selected.payment.account.name)})
                </span>
              </p>
              <p class="font-mono font-black">
                {format_currency(@selected.payment && @selected.payment.amount)}
              </p>
            </div>
            <button class="btn btn-ghost btn-sm text-error" phx-click="unlink">
              <.icon name="hero-link-slash" class="size-4" /> Desvincular
            </button>
          </div>

          <div :if={@selected.status == :pending} class="px-6 py-4 bg-warning/10">
            <p class="text-xs font-bold uppercase opacity-60">Fatura sem vencimento</p>
            <p class="text-sm opacity-40 italic mt-1">possível cobrança na próxima fatura</p>
          </div>

          <div :if={@selected.lifecycle == :absorbed} class="px-6 py-4 bg-base-200">
            <p class="text-xs font-bold uppercase opacity-60">
              Incorporada na fatura {format_competencia(@selected.absorbed_into)}
            </p>
            <.link
              :if={@selected.absorbed_by_id}
              patch={~p"/statements?id=#{@selected.absorbed_by_id}"}
              class="link"
            >
              ver fatura
            </.link>
          </div>

          <div
            :if={@selected.lifecycle in [:open, :closed] and @suggestion}
            id={"reconcile-#{@selected.statement.id}"}
            class="px-6 py-4 bg-warning/10 flex flex-wrap items-center justify-between gap-3"
          >
            <div>
              <p class="text-sm font-bold">Pagamento Detectado no Extrato Bancário!</p>
              <p class="text-xs opacity-70">
                {@suggestion.description} · {format_date(@suggestion.date)} · {@suggestion.account &&
                  @suggestion.account.name} ·
                <span class="font-mono font-bold">{format_currency(@suggestion.amount)}</span>
              </p>
            </div>
            <button
              class="btn btn-warning btn-sm"
              phx-click="link"
              phx-value-payment-id={@suggestion.id}
            >
              <.icon name="hero-link" class="size-4" /> Conciliar Pagamento em 1 Clique
            </button>
          </div>

          <div
            :if={@selected.lifecycle in [:open, :closed]}
            class="px-6 py-4 border-t border-base-200"
          >
            <p class="text-xs font-bold uppercase opacity-60 mb-2">Vincular pagamento manualmente</p>
            <p :if={@candidates == []} class="text-sm opacity-40 italic">
              Nenhum candidato a pagamento encontrado.
            </p>
            <div class="divide-y divide-base-200">
              <div
                :for={candidate <- @candidates}
                id={"candidate-#{candidate.id}"}
                class="py-2 flex flex-wrap items-center justify-between gap-2 text-xs"
              >
                <div>
                  <p class="font-bold">{candidate.description}</p>
                  <p class="opacity-40">
                    {format_date(candidate.date)} · {candidate.account && candidate.account.name}
                  </p>
                </div>
                <div class="flex items-center gap-3">
                  <span class="font-mono font-black">{format_currency(candidate.amount)}</span>
                  <button
                    class="btn btn-success btn-xs"
                    phx-click="link"
                    phx-value-payment-id={candidate.id}
                  >
                    Vincular
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
          <div class="px-6 py-4 border-b border-base-300">
            <h2 class="font-black uppercase tracking-tight text-sm">Lançamentos do ciclo</h2>
          </div>
          <div :if={@selected.transactions == []} class="px-6 py-12 text-center opacity-40 text-sm">
            Nenhum lançamento encontrado.
          </div>
          <table :if={@selected.transactions != []} class="table table-sm w-full text-xs">
            <thead>
              <tr>
                <th>Data</th>
                <th>Descrição</th>
                <th>Categoria</th>
                <th class="text-right">Valor</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={t <- @selected.transactions} class="hover">
                <td class="font-mono opacity-60 whitespace-nowrap">{format_date(t.date)}</td>
                <td>
                  {t.description}
                  <span :if={installment_label(t)} class="badge badge-ghost badge-xs ml-2">
                    {installment_label(t)}
                  </span>
                </td>
                <td>{t.category && t.category.name}</td>
                <td class="text-right font-mono font-black">{format_currency(t.amount)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
