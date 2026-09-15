defmodule CashLensWeb.ReimbursementLive.Index do
  @moduledoc """
  Reimbursement hub (`/reimbursements`).

  The screen is organised around the chronological lifecycle of a reimbursable
  expense:

    1. **A Solicitar** — marked as reimbursable, not yet filed with the
       carrier/company (action required).
    2. **Solicitado** — filed and waiting for the deposit.
    3. **Recebidos** — compensated and reconciled in the last 12 months.

  Two tabs (`?tab=pending` / `?tab=linked`) replace the previous stack of
  tables: "A Receber" lists expenses still waiting for money, "Histórico
  Vinculado" lists reconciled pairs. Every link written here is reversible
  through `Transactions.unlink_reimbursement_by_key/1`.
  """

  use CashLensWeb, :live_view

  alias CashLens.Transactions
  import CashLensWeb.Formatters

  # How many months back the "Recebidos" card looks.
  @received_window_days 365
  # Upper bound of rows pulled from the statement when looking for expenses to
  # mark as reimbursable. The context filters in SQL; the `reimbursement_status`
  # is nil check is applied in memory, so we over-fetch and trim afterwards.
  @statement_scan_limit 200
  @statement_result_limit 20

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6 relative">
      <.page_header
        to_request_count={@to_request_count}
        requested_count={@requested_count}
      />

      <.lifecycle_cards
        total_to_request={@total_to_request}
        to_request_count={@to_request_count}
        total_requested={@total_requested}
        requested_count={@requested_count}
        total_received_12m={@total_received_12m}
        received_12m_count={@received_12m_count}
      />

      <.suggestions_card suggestions={@suggestions} />

      <.tabs_bar
        tab={@tab}
        search={@search}
        unmatched_count={length(@unmatched)}
        linked_count={map_size(@paid_groups)}
        selected_count={MapSet.size(@selected_ids)}
        total_selected={@total_selected}
      />

      <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
        <.pending_table
          :if={@tab == :pending}
          rows={@visible_unmatched}
          selected_ids={@selected_ids}
        />
        <.linked_table :if={@tab == :linked} paid_groups={@paid_groups} />
      </div>
    </div>

    <.statement_modal
      :if={@show_statement_modal}
      candidates={@statement_candidates}
      search={@statement_search}
    />

    <.linker_modal
      :if={@show_linker_modal}
      unmatched={@unmatched}
      selected_ids={@selected_ids}
      total_selected={@total_selected}
      available_credits={@available_credits}
      selected_credit_ids={@selected_credit_ids}
      total_credits_selected={@total_credits_selected}
      linker_search={@linker_search}
      difference={@link_difference}
      perfect_match={@link_perfect_match}
    />

    <.confirm_modal :if={@confirm_modal} confirm_modal={@confirm_modal} />
    <.reconcile_modal :if={@reconcile_modal} reconcile_modal={@reconcile_modal} />
    """
  end

  attr :to_request_count, :integer, required: true
  attr :requested_count, :integer, required: true

  defp page_header(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
      <div>
        <div class="flex items-center gap-2.5">
          <h1 class="text-2xl font-black tracking-tight">Central de Reembolsos</h1>
          <span class="badge badge-warning badge-sm font-bold rounded-full">
            {@to_request_count + @requested_count} pendentes de recebimento
          </span>
        </div>
        <p class="text-xs opacity-50 mt-1">
          Acompanhe despesas médicas ou corporativas até a compensação do crédito na sua conta.
        </p>
      </div>

      <button
        phx-click="open_statement_modal"
        class="btn btn-outline btn-sm rounded-xl font-bold gap-2"
      >
        <.icon name="hero-plus-circle" class="size-4 text-primary" /> Marcar Despesa do Extrato
      </button>
    </div>
    """
  end

  attr :total_to_request, Decimal, required: true
  attr :to_request_count, :integer, required: true
  attr :total_requested, Decimal, required: true
  attr :requested_count, :integer, required: true
  attr :total_received_12m, Decimal, required: true
  attr :received_12m_count, :integer, required: true

  defp lifecycle_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <div class="bg-base-100 rounded-2xl p-5 border border-warning/40 shadow-sm flex flex-col justify-between">
        <div>
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[11px] font-bold uppercase tracking-wider text-warning">
              1. A Solicitar
            </span>
            <span class="badge badge-warning badge-outline badge-sm font-bold rounded-full text-[10px]">
              Ação Necessária
            </span>
          </div>
          <div class="text-2xl font-black text-warning font-mono">
            {format_currency(@total_to_request)}
          </div>
          <span class="text-xs opacity-50 mt-1 block">
            Transações marcadas como reembolso mas ainda não enviadas
          </span>
        </div>
        <div class="mt-4 pt-3 border-t border-base-200 text-xs opacity-60">
          {@to_request_count} despesa(s) aguardando solicitação
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl p-5 border border-info/40 shadow-sm flex flex-col justify-between">
        <div>
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[11px] font-bold uppercase tracking-wider text-info">
              2. Solicitado
            </span>
            <span class="badge badge-info badge-outline badge-sm font-bold rounded-full text-[10px]">
              Em Análise
            </span>
          </div>
          <div class="text-2xl font-black text-info font-mono">
            {format_currency(@total_requested)}
          </div>
          <span class="text-xs opacity-50 mt-1 block">
            Protocolos submetidos aguardando pagamento
          </span>
        </div>
        <div class="mt-4 pt-3 border-t border-base-200 text-xs opacity-60">
          {@requested_count} pedido(s) formalizado(s)
        </div>
      </div>

      <div class="bg-base-100 rounded-2xl p-5 border border-success/40 shadow-sm flex flex-col justify-between">
        <div>
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[11px] font-bold uppercase tracking-wider text-success">
              3. Recebidos
            </span>
            <span class="badge badge-success badge-outline badge-sm font-bold rounded-full text-[10px]">
              Últimos 12 meses
            </span>
          </div>
          <div class="text-2xl font-black text-success font-mono">
            {format_currency(@total_received_12m)}
          </div>
          <span class="text-xs opacity-50 mt-1 block">
            Total compensado e conciliado no período
          </span>
        </div>
        <div class="mt-4 pt-3 border-t border-base-200 text-xs opacity-60">
          {@received_12m_count} crédito(s) conciliado(s)
        </div>
      </div>
    </div>
    """
  end

  attr :suggestions, :list, required: true

  defp suggestions_card(assigns) do
    ~H"""
    <div
      :if={@suggestions != []}
      class="bg-success/5 border border-success/30 rounded-2xl p-5 shadow-sm space-y-4"
    >
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <div class="size-10 rounded-xl bg-success text-success-content flex items-center justify-center">
            <.icon name="hero-bolt" class="size-5" />
          </div>
          <div>
            <div class="flex items-center gap-2">
              <h2 class="text-sm font-black uppercase tracking-tight">
                Conciliação Automática Sugerida
              </h2>
              <span class="badge badge-success badge-sm font-bold rounded-full text-[10px]">
                {pair_count_label(@suggestions)}
              </span>
            </div>
            <p class="text-xs opacity-60 mt-0.5">
              Identificamos créditos bancários que batem com suas despesas em aberto.
            </p>
          </div>
        </div>

        <button
          phx-click="confirm_all_suggestions"
          class="btn btn-success btn-sm rounded-xl font-bold"
        >
          <.icon name="hero-check-circle" class="size-4 mr-1" /> Confirmar Todos
        </button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <div
          :for={{expense, credit} <- @suggestions}
          class="bg-base-100 rounded-xl border border-success/30 p-3.5 shadow-sm space-y-2.5"
        >
          <div class="flex items-center justify-between text-xs gap-2">
            <div class="flex items-center gap-2 min-w-0">
              <span class="badge badge-error badge-outline badge-xs text-[9px] font-bold shrink-0">
                Despesa
              </span>
              <span class="font-bold truncate" title={expense.description}>
                {expense.description}
              </span>
            </div>
            <span class="font-mono font-bold text-error shrink-0">
              {format_currency(expense.amount)}
            </span>
          </div>

          <div class="flex items-center justify-between text-xs gap-2">
            <div class="flex items-center gap-2 min-w-0">
              <span class="badge badge-success badge-outline badge-xs text-[9px] font-bold shrink-0">
                Crédito
              </span>
              <span class="font-bold truncate text-success" title={credit.description}>
                {credit.description}
              </span>
            </div>
            <span class="font-mono font-bold text-success shrink-0">
              {format_currency(credit.amount)}
            </span>
          </div>

          <div class="pt-2 border-t border-base-200 flex items-center justify-between text-[11px]">
            <span class="opacity-50 font-mono">
              {format_date(expense.date)} → {format_date(credit.date)}
            </span>
            <div class="flex items-center gap-1.5">
              <button
                class="btn btn-ghost btn-xs rounded-lg font-bold text-error/70"
                phx-click="confirm_reject_pair"
                phx-value-a={expense.id}
                phx-value-b={credit.id}
              >
                Ignorar
              </button>
              <button
                class="btn btn-success btn-xs rounded-lg font-bold"
                phx-click="confirm_pair"
                phx-value-a={expense.id}
                phx-value-b={credit.id}
              >
                <.icon name="hero-check" class="size-3" /> Conciliar
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :search, :string, required: true
  attr :unmatched_count, :integer, required: true
  attr :linked_count, :integer, required: true
  attr :selected_count, :integer, required: true
  attr :total_selected, Decimal, required: true

  defp tabs_bar(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm p-4 space-y-3">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div class="flex items-center bg-base-200 p-1 rounded-xl w-fit">
          <.link
            patch={~p"/reimbursements?tab=pending"}
            class={[
              "px-4 py-1.5 rounded-lg text-xs font-bold transition flex items-center gap-1.5",
              @tab == :pending && "bg-base-100 shadow-sm"
            ]}
          >
            <span>A Receber</span>
            <span class="badge badge-primary badge-xs text-[10px]">{@unmatched_count}</span>
          </.link>
          <.link
            patch={~p"/reimbursements?tab=linked"}
            class={[
              "px-4 py-1.5 rounded-lg text-xs font-bold transition flex items-center gap-1.5",
              @tab == :linked && "bg-base-100 shadow-sm"
            ]}
          >
            <span>Histórico Vinculado</span>
            <span class="badge badge-ghost badge-xs text-[10px]">{@linked_count}</span>
          </.link>
        </div>

        <div :if={@tab == :pending} class="relative w-full sm:max-w-xs">
          <input
            type="text"
            name="value"
            value={@search}
            phx-keyup="search_change"
            phx-debounce="300"
            placeholder="Buscar por médico, clínica, convênio ou valor..."
            class="input input-bordered input-sm w-full rounded-xl bg-base-200 border-none text-xs"
          />
        </div>
      </div>

      <div
        :if={@selected_count > 0}
        class="bg-neutral text-neutral-content rounded-xl p-3 flex flex-col sm:flex-row sm:items-center justify-between gap-3"
      >
        <div class="flex items-center gap-3">
          <span class="badge badge-primary badge-sm font-bold">
            {@selected_count} {selected_label(@selected_count)}
          </span>
          <span class="text-xs font-mono font-bold">
            Total Selecionado: {format_currency(@total_selected)}
          </span>
        </div>

        <div class="flex items-center gap-2">
          <button
            phx-click="open_batch_linker"
            class="btn btn-primary btn-xs rounded-lg font-bold gap-1.5"
          >
            <.icon name="hero-link" class="size-3.5" /> Vincular a um Crédito
          </button>
          <button phx-click="clear_selection" class="btn btn-ghost btn-xs rounded-lg">
            Cancelar
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :selected_ids, :any, required: true

  defp pending_table(assigns) do
    ~H"""
    <div :if={@rows == []} class="py-12 px-4 text-center">
      <h3 class="text-sm font-bold">Tudo em dia!</h3>
      <p class="text-xs opacity-40 mt-1">Nenhuma despesa pendente de reembolso neste filtro.</p>
    </div>

    <div :if={@rows != []} class="overflow-x-auto">
      <table class="table table-sm w-full text-xs">
        <thead class="bg-base-200/60 text-[10px] uppercase tracking-wider">
          <tr>
            <th class="w-8"></th>
            <th>Data</th>
            <th>Despesa Reembolsável</th>
            <th>Conta / Cartão</th>
            <th>Status no Ciclo</th>
            <th class="text-right">Valor Gasto</th>
            <th class="text-center w-32">Ações</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={tx <- @rows}
            class={["hover", MapSet.member?(@selected_ids, tx.id) && "bg-primary/5"]}
          >
            <td>
              <input
                type="checkbox"
                class="checkbox checkbox-primary checkbox-xs rounded"
                checked={MapSet.member?(@selected_ids, tx.id)}
                phx-click="toggle_selection"
                phx-value-id={tx.id}
              />
            </td>
            <td class="whitespace-nowrap font-mono opacity-60">{format_date(tx.date)}</td>
            <td>
              <div class="font-bold">{tx.description}</div>
              <div class="flex items-center gap-2 text-[10px] opacity-60 mt-0.5">
                <span :if={tx.category} class="badge badge-ghost badge-xs text-[9px]">
                  {tx.category.name}
                </span>
                <span :if={tx.reimbursement_carrier}>
                  Convênio: <b>{tx.reimbursement_carrier}</b>
                </span>
                <span :if={tx.reimbursement_protocol}>
                  Protocolo: <b class="font-mono text-primary">{tx.reimbursement_protocol}</b>
                </span>
              </div>
              <form
                phx-submit="save_reimbursement_details"
                data-tx-id={tx.id}
                class="flex items-center gap-1 mt-1"
              >
                <input type="hidden" name="tx_id" value={tx.id} />
                <input
                  type="text"
                  name="carrier"
                  value={tx.reimbursement_carrier}
                  placeholder="Convênio"
                  class="input input-xs input-bordered rounded-lg w-28 text-[10px]"
                />
                <input
                  type="text"
                  name="protocol"
                  value={tx.reimbursement_protocol}
                  placeholder="Protocolo"
                  class="input input-xs input-bordered rounded-lg w-32 text-[10px]"
                />
                <button type="submit" class="btn btn-ghost btn-xs" title="Salvar convênio/protocolo">
                  <.icon name="hero-check" class="size-3" />
                </button>
              </form>
            </td>
            <td class="uppercase font-bold text-[9px] whitespace-nowrap leading-tight opacity-60">
              <div>{tx.account.bank}</div>
              <div class="opacity-70">{tx.account.name}</div>
            </td>
            <td class="whitespace-nowrap">
              <span
                :if={tx.reimbursement_status == "requested"}
                class="badge badge-info badge-sm font-bold text-[10px] rounded-full"
              >
                Solicitado (Em Análise)
              </span>
              <span
                :if={tx.reimbursement_status != "requested"}
                class="badge badge-warning badge-sm font-bold text-[10px] rounded-full"
              >
                Pendente de Solicitação
              </span>
            </td>
            <td class="text-right font-mono font-black text-error whitespace-nowrap">
              {format_currency(tx.amount)}
            </td>
            <td class="text-center">
              <div class="flex justify-center gap-1">
                <button
                  phx-click="link_single_expense"
                  phx-value-id={tx.id}
                  class="btn btn-ghost btn-xs text-success"
                  title="Vincular Crédito Recebido"
                >
                  <.icon name="hero-link" class="size-4" />
                </button>
                <button
                  :if={tx.reimbursement_status != "requested"}
                  phx-click="mark_requested"
                  phx-value-id={tx.id}
                  class="btn btn-ghost btn-xs text-info"
                  title="Marcar como Solicitado ao Plano"
                >
                  <.icon name="hero-paper-airplane" class="size-4" />
                </button>
                <button
                  :if={tx.reimbursement_status == "requested"}
                  phx-click="mark_pending"
                  phx-value-id={tx.id}
                  class="btn btn-ghost btn-xs text-warning"
                  title="Reverter para Pendente"
                >
                  <.icon name="hero-arrow-uturn-left" class="size-4" />
                </button>
                <button
                  phx-click="remove_reimbursable"
                  phx-value-id={tx.id}
                  class="btn btn-ghost btn-xs text-error opacity-40 hover:opacity-100"
                  title="Não é Reembolsável"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :paid_groups, :map, required: true

  defp linked_table(assigns) do
    ~H"""
    <div :if={@paid_groups == %{}} class="py-12 px-4 text-center">
      <h3 class="text-sm font-bold">Nenhum reembolso vinculado ainda.</h3>
      <p class="text-xs opacity-40 mt-1">
        Concilie uma despesa com seu crédito para vê-la aqui.
      </p>
    </div>

    <div :if={@paid_groups != %{}} class="overflow-x-auto">
      <table class="table table-sm w-full text-xs">
        <thead class="bg-base-200/60 text-[10px] uppercase tracking-wider">
          <tr>
            <th>Despesa Original</th>
            <th>Crédito de Reembolso Compensado</th>
            <th class="text-right">Valor Conciliado</th>
            <th class="text-center w-28">Ações</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{link_key, txs} <- @paid_groups} class="hover align-top">
            <td class="py-3 space-y-1">
              <div :for={ex <- expense_side(txs)} class="flex items-center justify-between gap-4">
                <div class="min-w-0">
                  <span class="font-bold">{ex.description}</span>
                  <span class="text-[10px] opacity-50 block">
                    {format_date(ex.date)} · {tx_account_label(ex)}
                  </span>
                </div>
                <span class="font-mono font-bold text-error shrink-0">
                  {format_currency(ex.amount)}
                </span>
              </div>
            </td>
            <td class="py-3 space-y-1 border-l border-base-200">
              <div :for={cr <- credit_side(txs)} class="flex items-center justify-between gap-4">
                <div class="min-w-0">
                  <span class="font-bold text-success">{cr.description}</span>
                  <span class="text-[10px] opacity-50 block">
                    {format_date(cr.date)} · {tx_account_label(cr)}
                  </span>
                </div>
                <span class="font-mono font-bold text-success shrink-0">
                  {format_currency(cr.amount)}
                </span>
              </div>
              <p :if={credit_side(txs) == []} class="text-[10px] text-warning italic">
                Crédito não encontrado ou excluído.
              </p>
            </td>
            <td class="text-right font-mono font-black text-success">
              {format_currency(reconciled_total(txs))}
            </td>
            <td class="text-center">
              <button
                class="btn btn-ghost btn-xs font-bold"
                phx-click="confirm_unlink_reimbursement"
                phx-value-link-key={link_key}
                title="Desfazer conciliação"
              >
                <.icon name="hero-link-slash" class="size-3 mr-1" /> Desvincular
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :candidates, :list, required: true
  attr :search, :string, required: true

  defp statement_modal(assigns) do
    ~H"""
    <.modal id="statement-modal" show on_cancel={JS.push("close_statement_modal")}>
      <div class="p-2 space-y-4">
        <div>
          <h2 class="text-lg font-black tracking-tight">Marcar Despesa como Reembolsável</h2>
          <p class="text-xs opacity-50">
            Escolha transações recentes do extrato para acompanhar o reembolso
          </p>
        </div>

        <input
          type="text"
          name="value"
          value={@search}
          phx-keyup="statement_search_change"
          phx-debounce="300"
          placeholder="Buscar por descrição (médico, clínica, Uber) ou valor (ex: 350 ou 84,20)..."
          class="input input-bordered w-full rounded-xl bg-base-200 border-none text-xs"
        />

        <div id="statement-candidates" class="space-y-2 max-h-72 overflow-y-auto pr-1">
          <p :if={@candidates == []} class="text-center py-8 opacity-40 text-xs italic">
            Nenhuma despesa encontrada.
          </p>

          <div
            :for={tx <- @candidates}
            class="p-3 rounded-xl border border-base-300 flex items-center justify-between gap-3"
          >
            <div class="min-w-0">
              <span class="font-bold block truncate">{tx.description}</span>
              <span class="text-[10px] opacity-50">
                {format_date(tx.date)} · {tx_account_label(tx)}{category_suffix(tx)}
              </span>
            </div>
            <div class="text-right shrink-0">
              <span class="font-mono font-bold text-error block">{format_currency(tx.amount)}</span>
              <button
                phx-click="mark_reimbursable"
                phx-value-id={tx.id}
                class="btn btn-primary btn-xs rounded-lg font-bold mt-1"
              >
                + Adicionar
              </button>
            </div>
          </div>
        </div>

        <div class="flex justify-end">
          <button phx-click="close_statement_modal" class="btn btn-ghost btn-sm rounded-xl">
            Fechar
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :unmatched, :list, required: true
  attr :selected_ids, :any, required: true
  attr :total_selected, Decimal, required: true
  attr :available_credits, :list, required: true
  attr :selected_credit_ids, :any, required: true
  attr :total_credits_selected, Decimal, required: true
  attr :linker_search, :string, required: true
  attr :difference, Decimal, required: true
  attr :perfect_match, :boolean, required: true

  defp linker_modal(assigns) do
    ~H"""
    <.modal id="linker-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-2 space-y-4">
        <div>
          <h2 class="text-lg font-black tracking-tight text-success">
            Vincular Crédito de Reembolso
          </h2>
          <p class="text-xs opacity-50">
            Associe o depósito bancário às despesas que ele cobre
          </p>
        </div>

        <div class="bg-base-200 rounded-xl p-3 space-y-1">
          <span class="text-[10px] font-bold uppercase tracking-wider opacity-50 block">
            Despesas Selecionadas para Quitar
          </span>
          <div
            :for={tx <- Enum.filter(@unmatched, &MapSet.member?(@selected_ids, &1.id))}
            class="flex items-center justify-between text-xs gap-3"
          >
            <span class="truncate">{tx.description}</span>
            <span class="font-mono font-bold text-error shrink-0">
              {format_currency(tx.amount)}
            </span>
          </div>
          <div class="border-t border-base-300 pt-1 mt-1 flex justify-between text-xs font-black">
            <span class="opacity-50 uppercase tracking-wider">Total a Cobrir</span>
            <span class="text-error font-mono">{format_currency(@total_selected)}</span>
          </div>
        </div>

        <p class="text-xs opacity-50">
          Selecione um ou mais créditos recebidos no banco que cubram esta despesa:
        </p>

        <input
          type="text"
          name="value"
          value={@linker_search}
          phx-keyup="linker_search_change"
          phx-debounce="300"
          placeholder="Filtrar créditos (ex: TED, UNIMED, PIX ou valor)..."
          class="input input-bordered w-full rounded-xl bg-base-200 border-none text-xs"
        />

        <div class="space-y-2 max-h-64 overflow-y-auto pr-1">
          <p :if={@available_credits == []} class="text-center py-8 opacity-40 text-xs italic">
            Nenhum crédito disponível encontrado.
          </p>

          <button
            :for={credit <- @available_credits}
            type="button"
            phx-click="toggle_credit"
            phx-value-credit-id={credit.id}
            class={[
              "w-full text-left flex items-center gap-3 p-3 border-2 rounded-xl transition-all",
              if(MapSet.member?(@selected_credit_ids, credit.id),
                do: "border-success bg-success/5",
                else: "border-base-300 hover:border-success"
              )
            ]}
          >
            <div class={[
              "size-5 rounded-full border-2 flex items-center justify-center shrink-0",
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
              <div class="flex items-center gap-1.5">
                <span class="font-black text-sm truncate">{credit.description}</span>
                <span
                  :if={amounts_match?(credit.amount, @total_selected)}
                  class="badge badge-success badge-xs text-[9px] font-bold"
                >
                  Match Perfeito
                </span>
              </div>
              <div class="text-[10px] font-bold uppercase opacity-50">
                {format_date(credit.date)} · {tx_account_label(credit)}
              </div>
            </div>
            <span class="font-black text-success shrink-0">{format_currency(credit.amount)}</span>
          </button>
        </div>

        <div
          :if={MapSet.size(@selected_credit_ids) > 0}
          class={[
            "p-3 rounded-xl border text-xs flex items-center justify-between gap-3",
            if(@perfect_match,
              do: "bg-success/10 border-success/40",
              else: "bg-warning/10 border-warning/40"
            )
          ]}
        >
          <span :if={@perfect_match} class="font-bold text-success">
            Match Perfeito! Valores 100% coincidentes.
          </span>
          <span :if={!@perfect_match} class="font-bold text-warning">
            Reembolso parcial ou divergente
          </span>
          <span class="font-mono font-bold whitespace-nowrap">
            Saldo: {format_currency(@difference)}
          </span>
        </div>

        <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
          <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm rounded-xl">
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirm_link"
            disabled={MapSet.size(@selected_credit_ids) == 0}
            class="btn btn-success btn-sm rounded-xl font-black disabled:opacity-30"
          >
            <.icon name="hero-link" class="size-4 mr-1" /> Confirmar Vínculo
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :confirm_modal, :map, required: true

  defp confirm_modal(assigns) do
    ~H"""
    <.modal id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class={[
          "w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-6",
          @confirm_modal.icon_class
        ]}>
          <.icon name={@confirm_modal.icon} class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2 uppercase tracking-tighter">{@confirm_modal.title}</h2>
        <p class="text-base-content/60 mb-10">{@confirm_modal.message}</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button
            phx-click={@confirm_modal.action}
            class={["btn btn-lg flex-1 rounded-2xl", @confirm_modal.confirm_class]}
          >
            {@confirm_modal.confirm_text}
          </button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">
            Cancelar
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :reconcile_modal, :map, required: true

  defp reconcile_modal(assigns) do
    ~H"""
    <.modal id="reconcile-modal" show on_cancel={JS.push("close_reconcile_modal")}>
      <div class="p-4">
        <div class="w-20 h-20 rounded-full bg-warning/10 text-warning flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-tag" class="size-10" />
        </div>
        <h2 class="text-2xl font-black text-center mb-2 uppercase tracking-tighter">
          Conciliar Categoria
        </h2>
        <p class="text-base-content/60 text-center mb-6">
          As transações vinculadas a um reembolso devem possuir a mesma categoria.
        </p>

        <div :if={@reconcile_modal.type == :select} class="space-y-4">
          <p class="text-xs font-semibold text-center mb-4 opacity-75">
            Nenhuma das transações possui categoria. Selecione uma categoria para ambas:
          </p>
          <form phx-submit="confirm_reconcile_select" class="space-y-4">
            <select
              name="category_id"
              class="select select-bordered w-full rounded-2xl bg-base-200 border-none"
              required
            >
              <option value="" disabled selected>Escolha uma categoria...</option>
              <option :for={cat <- @reconcile_modal.categories} value={cat.id}>{cat.name}</option>
            </select>
            <button type="submit" class="btn btn-primary w-full rounded-2xl font-black">
              Confirmar Categoria
            </button>
          </form>
        </div>

        <div :if={@reconcile_modal.type != :select} class="space-y-6">
          <p class="text-xs font-semibold text-center mb-4 opacity-75">
            Ambas as transações possuem categorias diferentes. Escolha qual categoria deseja manter para ambas:
          </p>
          <div class="flex flex-col gap-3">
            <button
              :for={cat <- @reconcile_modal.categories}
              type="button"
              phx-click="confirm_reconcile_button"
              phx-value-category-id={cat.id}
              class="btn btn-outline btn-lg rounded-2xl font-black flex items-center justify-between px-6"
            >
              <span>Usar: {cat.name}</span>
            </button>
          </div>
        </div>

        <button phx-click="close_reconcile_modal" class="btn btn-ghost w-full mt-4 rounded-2xl">
          Cancelar
        </button>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tab, :pending)
     |> assign(:search, "")
     |> assign(:selected_ids, MapSet.new())
     |> assign(:total_selected, Decimal.new("0"))
     |> assign(:show_linker_modal, false)
     |> assign(:linker_search, "")
     |> assign(:available_credits, [])
     |> assign(:selected_credit_ids, MapSet.new())
     |> assign(:total_credits_selected, Decimal.new("0"))
     |> assign(:link_difference, Decimal.new("0"))
     |> assign(:link_perfect_match, false)
     |> assign(:show_statement_modal, false)
     |> assign(:statement_search, "")
     |> assign(:statement_candidates, [])
     |> assign(:confirm_modal, nil)
     |> assign(:reconcile_modal, nil)
     |> load_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, parse_tab(params["tab"]))}
  end

  defp parse_tab("linked"), do: :linked
  defp parse_tab(_), do: :pending

  @impl true
  def handle_event("search_change", %{"value" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> apply_search()}
  end

  def handle_event("toggle_selection", %{"id" => id}, socket) do
    new_selection =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply, assign_selection(socket, new_selection)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign_selection(socket, MapSet.new())}
  end

  def handle_event("confirm_pair", %{"a" => id_a, "b" => id_b}, socket) do
    expense = Transactions.get_transaction!(id_a)
    credit = Transactions.get_transaction!(id_b)

    {expense, credit} =
      if Decimal.lt?(expense.amount, 0), do: {expense, credit}, else: {credit, expense}

    link_or_reconcile(socket, [expense], [credit])
  end

  def handle_event("confirm_reject_pair", %{"a" => id_a, "b" => id_b}, socket) do
    confirm = %{
      title: "Ignorar Sugestão?",
      message:
        "Deseja marcar que este par não é um reembolso? O sistema tentará sugerir outros pares.",
      action: JS.push("reject_pair", value: %{a: id_a, b: id_b}),
      confirm_text: "Sim, Ignorar",
      confirm_class: "btn-error",
      icon: "hero-x-mark",
      icon_class: "bg-error/10 text-error"
    }

    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  def handle_event("reject_pair", %{"a" => id_a, "b" => id_b}, socket) do
    {:ok, _} = Transactions.reject_reimbursement_pair(id_a, id_b)

    {:noreply,
     socket
     |> put_flash(:success, "Sugestão de reembolso ignorada.")
     |> assign(:confirm_modal, nil)
     |> load_data()}
  end

  def handle_event("confirm_all_suggestions", _params, socket) do
    confirm = %{
      title: "Confirmar Todos os Pares?",
      message:
        "Deseja confirmar todos os #{length(socket.assigns.suggestions)} pares de sugestão de reembolso?",
      action: JS.push("confirm_all"),
      confirm_text: "Confirmar Todos",
      confirm_class: "btn-primary",
      icon: "hero-check",
      icon_class: "bg-primary/10 text-primary"
    }

    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  def handle_event("confirm_all", _params, socket) do
    Enum.each(socket.assigns.suggestions, fn {a, b} ->
      Transactions.link_reimbursement_pair(a.id, b.id)
    end)

    count = length(socket.assigns.suggestions)

    {:noreply,
     socket
     |> put_flash(:success, "#{count} reembolsos vinculados com sucesso!")
     |> assign(:confirm_modal, nil)
     |> load_data()}
  end

  def handle_event("mark_requested", %{"id" => id}, socket) do
    {:noreply, update_status(socket, id, "requested")}
  end

  def handle_event("mark_pending", %{"id" => id}, socket) do
    {:noreply, update_status(socket, id, "pending")}
  end

  def handle_event("remove_reimbursable", %{"id" => id}, socket) do
    {:noreply, update_status(socket, id, nil)}
  end

  def handle_event("save_reimbursement_details", params, socket) do
    tx = Transactions.get_transaction!(params["tx_id"])

    {:ok, _} =
      Transactions.update_transaction(tx, %{
        reimbursement_carrier: blank_to_nil(params["carrier"]),
        reimbursement_protocol: blank_to_nil(params["protocol"])
      })

    {:noreply, socket |> put_flash(:success, "Dados do reembolso salvos.") |> load_data()}
  end

  def handle_event("open_statement_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_statement_modal, true)
     |> assign(:statement_search, "")
     |> load_statement_candidates()}
  end

  def handle_event("close_statement_modal", _params, socket) do
    {:noreply, assign(socket, :show_statement_modal, false)}
  end

  def handle_event("statement_search_change", %{"value" => search}, socket) do
    {:noreply, socket |> assign(:statement_search, search) |> load_statement_candidates()}
  end

  def handle_event("mark_reimbursable", %{"id" => id}, socket) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: "pending"})

    {:noreply,
     socket
     |> put_flash(:success, "Despesa marcada como reembolsável.")
     |> load_data()
     |> load_statement_candidates()}
  end

  def handle_event("link_single_expense", %{"id" => id}, socket) do
    {:noreply, socket |> assign_selection(MapSet.new([id])) |> open_linker()}
  end

  def handle_event("open_batch_linker", _params, socket) do
    {:noreply, open_linker(socket)}
  end

  def handle_event("confirm_unlink_reimbursement", %{"link-key" => link_key}, socket) do
    confirm = %{
      title: "Desvincular Reembolso?",
      message:
        "Deseja desvincular este reembolso? A despesa voltará a ficar pendente de reembolso.",
      action: JS.push("unlink_reimbursement", value: %{"link-key" => link_key}),
      confirm_text: "Sim, Desvincular",
      confirm_class: "btn-error",
      icon: "hero-link-slash",
      icon_class: "bg-error/10 text-error"
    }

    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  def handle_event("unlink_reimbursement", %{"link-key" => link_key}, socket) do
    :ok = Transactions.unlink_reimbursement_by_key(link_key)

    {:noreply,
     socket
     |> put_flash(:success, "Reembolso desvinculado com sucesso.")
     |> assign(:confirm_modal, nil)
     |> load_data()}
  end

  def handle_event("linker_search_change", %{"value" => search}, socket) do
    {:noreply, socket |> assign(:linker_search, search) |> update_linker_list()}
  end

  def handle_event("toggle_credit", %{"credit-id" => credit_id}, socket) do
    selected = socket.assigns.selected_credit_ids

    new_selected =
      if MapSet.member?(selected, credit_id),
        do: MapSet.delete(selected, credit_id),
        else: MapSet.put(selected, credit_id)

    {:noreply, assign_credit_selection(socket, new_selected)}
  end

  def handle_event("confirm_link", _params, socket) do
    expenses = Enum.map(socket.assigns.selected_ids, &Transactions.get_transaction!/1)
    credits = Enum.map(socket.assigns.selected_credit_ids, &Transactions.get_transaction!/1)

    link_or_reconcile(socket, expenses, credits)
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_linker_modal, false)
     |> assign(:confirm_modal, nil)
     |> assign_credit_selection(MapSet.new())}
  end

  def handle_event("confirm_reconcile_select", %{"category_id" => category_id}, socket) do
    {:noreply, finish_link(socket, category_id)}
  end

  def handle_event("confirm_reconcile_button", %{"category-id" => category_id}, socket) do
    {:noreply, finish_link(socket, category_id)}
  end

  def handle_event("close_reconcile_modal", _params, socket) do
    {:noreply, assign(socket, :reconcile_modal, nil)}
  end

  # -- linking ---------------------------------------------------------------

  # Decides whether the expense/credit set can be linked straight away or
  # whether the user first has to pick the category both sides will share.
  defp link_or_reconcile(socket, expenses, credits) do
    categories =
      (expenses ++ credits)
      |> Enum.map(& &1.category_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    expense_ids = Enum.map(expenses, & &1.id)
    credit_ids = Enum.map(credits, & &1.id)

    case categories do
      [] ->
        {:noreply,
         open_reconcile(socket, expense_ids, credit_ids, :select, list_all_categories())}

      [category_id] ->
        {:noreply,
         socket
         |> assign(:reconcile_modal, %{expense_ids: expense_ids, credit_ids: credit_ids})
         |> finish_link(category_id)}

      ids ->
        cats = Enum.map(ids, &CashLens.Categories.get_category!/1)
        {:noreply, open_reconcile(socket, expense_ids, credit_ids, :buttons, cats)}
    end
  end

  defp open_reconcile(socket, expense_ids, credit_ids, type, categories) do
    assign(socket, :reconcile_modal, %{
      expense_ids: expense_ids,
      credit_ids: credit_ids,
      type: type,
      categories: categories
    })
  end

  defp finish_link(socket, category_id) do
    %{expense_ids: expense_ids, credit_ids: credit_ids} = socket.assigns.reconcile_modal

    {:ok, _} = Transactions.link_reimbursement_group(expense_ids, credit_ids, category_id)

    socket
    |> put_flash(
      :success,
      "Reembolso vinculado com sucesso! #{length(credit_ids)} crédito(s) conciliado(s)."
    )
    |> assign(:reconcile_modal, nil)
    |> assign(:show_linker_modal, false)
    |> assign_credit_selection(MapSet.new())
    |> assign_selection(MapSet.new())
    |> load_data()
  end

  defp list_all_categories, do: CashLens.Categories.list_categories()

  # -- selection helpers -----------------------------------------------------

  defp assign_selection(socket, selection) do
    total =
      socket.assigns.unmatched
      |> Enum.filter(&MapSet.member?(selection, &1.id))
      |> sum_amounts()
      |> Decimal.abs()

    socket
    |> assign(:selected_ids, selection)
    |> assign(:total_selected, total)
    |> recalculate_match()
  end

  defp assign_credit_selection(socket, selection) do
    total =
      socket.assigns.available_credits
      |> Enum.filter(&MapSet.member?(selection, &1.id))
      |> sum_amounts()

    socket
    |> assign(:selected_credit_ids, selection)
    |> assign(:total_credits_selected, total)
    |> recalculate_match()
  end

  # The partial-balance arithmetic: how much of the selected expenses the
  # selected credits actually cover. Positive means the credits exceed the
  # expenses, negative means part of the expense is still uncovered.
  defp recalculate_match(socket) do
    target = socket.assigns.total_selected
    credits = socket.assigns.total_credits_selected
    difference = Decimal.sub(credits, target)

    socket
    |> assign(:link_difference, difference)
    |> assign(:link_perfect_match, Decimal.eq?(Decimal.round(difference, 2), Decimal.new("0")))
  end

  defp sum_amounts(transactions) do
    Enum.reduce(transactions, Decimal.new("0"), &Decimal.add(&2, &1.amount))
  end

  defp amounts_match?(credit_amount, target) do
    Decimal.eq?(Decimal.round(credit_amount, 2), Decimal.round(target, 2))
  end

  defp open_linker(socket) do
    socket
    |> assign(:show_linker_modal, true)
    |> assign(:linker_search, "")
    |> update_linker_list()
    |> assign_credit_selection(MapSet.new())
  end

  defp update_status(socket, id, status) do
    tx = Transactions.get_transaction!(id)
    {:ok, _} = Transactions.update_transaction(tx, %{reimbursement_status: status})

    socket
    |> assign_selection(MapSet.delete(socket.assigns.selected_ids, id))
    |> load_data()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # -- data loading ----------------------------------------------------------

  defp load_data(socket) do
    suggestions = Transactions.list_reimbursement_suggestions()
    unmatched = Transactions.list_unmatched_reimbursements_without_suggestion()

    pending = Transactions.list_all_transactions(%{"reimbursement_status" => "pending"})
    requested = Transactions.list_all_transactions(%{"reimbursement_status" => "requested"})
    paid = Transactions.list_all_transactions(%{"reimbursement_status" => "paid"})

    received = received_last_12_months(paid)

    socket
    |> assign(:suggestions, suggestions)
    |> assign(:unmatched, unmatched)
    |> assign(:paid_groups, group_paid(paid))
    |> assign(:total_to_request, absolute_total(pending))
    |> assign(:to_request_count, length(pending))
    |> assign(:total_requested, absolute_total(requested))
    |> assign(:requested_count, length(requested))
    |> assign(:total_received_12m, sum_amounts(received))
    |> assign(:received_12m_count, length(received))
    |> apply_search()
  end

  defp group_paid(paid) do
    paid
    |> Enum.filter(& &1.reimbursement_link_key)
    |> Enum.group_by(& &1.reimbursement_link_key)
  end

  # Only the credit legs count as money actually received, and only those
  # compensated inside the rolling 12-month window.
  defp received_last_12_months(paid) do
    cutoff = Date.add(Date.utc_today(), -@received_window_days)

    Enum.filter(paid, fn tx ->
      Decimal.gt?(tx.amount, 0) and not is_nil(tx.reimbursement_link_key) and
        Date.compare(tx.date, cutoff) != :lt
    end)
  end

  defp absolute_total(transactions), do: transactions |> sum_amounts() |> Decimal.abs()

  defp apply_search(socket) do
    assign(
      socket,
      :visible_unmatched,
      filter_rows(socket.assigns.unmatched, socket.assigns.search)
    )
  end

  defp filter_rows(rows, search) do
    case String.trim(search || "") do
      "" -> rows
      term -> Enum.filter(rows, &row_matches?(&1, String.downcase(term)))
    end
  end

  defp row_matches?(tx, term) do
    [
      tx.description,
      tx.reimbursement_carrier,
      tx.reimbursement_protocol,
      tx.category && tx.category.name,
      tx.account && tx.account.bank,
      tx.account && tx.account.name,
      Decimal.to_string(Decimal.abs(tx.amount))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), term))
  end

  # -- statement candidates --------------------------------------------------

  defp load_statement_candidates(socket) do
    candidates =
      socket.assigns.statement_search
      |> String.trim()
      |> fetch_statement_candidates()

    assign(socket, :statement_candidates, candidates)
  end

  defp fetch_statement_candidates("") do
    %{"type" => "expense", "sort_order" => "desc"}
    |> scan_statement()
    |> finish_candidates()
  end

  defp fetch_statement_candidates(term) do
    by_description =
      scan_statement(%{"type" => "expense", "sort_order" => "desc", "search" => term})

    by_amount =
      case numeric_term(term) do
        nil ->
          []

        amount ->
          scan_statement(%{"type" => "expense", "sort_order" => "desc", "amount" => amount})
      end

    (by_description ++ by_amount)
    |> Enum.uniq_by(& &1.id)
    |> finish_candidates()
  end

  defp scan_statement(filters) do
    Transactions.list_transactions(filters, 1, @statement_scan_limit)
  end

  # Only transactions that are not part of the reimbursement flow yet may be
  # added from here; the /transactions screen owns un-marking them again.
  defp finish_candidates(transactions) do
    transactions
    |> Enum.filter(&is_nil(&1.reimbursement_status))
    |> Enum.sort_by(& &1.date, {:desc, Date})
    |> Enum.take(@statement_result_limit)
  end

  # "350" / "84,20" are amount searches; anything else is a description search.
  defp numeric_term(term) do
    normalized = String.replace(term, ",", ".")

    case Float.parse(normalized) do
      {_value, ""} -> normalized
      _ -> nil
    end
  end

  # -- linker candidates -----------------------------------------------------

  defp update_linker_list(socket) do
    target = Decimal.round(socket.assigns.total_selected, 2)
    search = String.downcase(String.trim(socket.assigns.linker_search))
    expense_date = selected_expense_date(socket)

    desc_search = if numeric_term(search), do: "", else: search

    sorted =
      desc_search
      |> Transactions.list_reimbursement_credit_candidates()
      |> filter_credits(search)
      |> Enum.sort(&credit_rank(&1, &2, target, expense_date))
      |> Enum.take(30)

    assign(socket, :available_credits, sorted)
  end

  defp selected_expense_date(socket) do
    socket.assigns.unmatched
    |> Enum.find(&MapSet.member?(socket.assigns.selected_ids, &1.id))
    |> then(&(&1 && &1.date))
  end

  defp filter_credits(credits, ""), do: credits

  defp filter_credits(credits, search) do
    Enum.filter(credits, fn tx ->
      String.contains?(String.downcase(tx.description), search) or
        String.contains?(Decimal.to_string(tx.amount), search)
    end)
  end

  defp credit_rank(a, b, target, expense_date) do
    exact_a = Decimal.eq?(Decimal.round(a.amount, 2), target)
    exact_b = Decimal.eq?(Decimal.round(b.amount, 2), target)

    cond do
      exact_a != exact_b ->
        exact_a

      expense_date != nil ->
        abs(Date.diff(a.date, expense_date)) <= abs(Date.diff(b.date, expense_date))

      true ->
        Date.compare(a.date, b.date) != :lt
    end
  end

  # -- view helpers ----------------------------------------------------------

  defp expense_side(txs), do: Enum.filter(txs, &Decimal.lt?(&1.amount, 0))
  defp credit_side(txs), do: Enum.filter(txs, &Decimal.gt?(&1.amount, 0))

  defp reconciled_total(txs), do: txs |> credit_side() |> sum_amounts()

  defp tx_account_label(%{account: %{bank: bank, name: name}}), do: "#{bank} - #{name}"
  defp tx_account_label(_tx), do: ""

  defp category_suffix(%{category: %{name: name}}), do: " · #{name}"
  defp category_suffix(_tx), do: ""

  defp selected_label(1), do: "selecionado"
  defp selected_label(_count), do: "selecionados"

  defp pair_count_label([_single]), do: "1 par encontrado"
  defp pair_count_label(pairs), do: "#{length(pairs)} pares encontrados"
end
