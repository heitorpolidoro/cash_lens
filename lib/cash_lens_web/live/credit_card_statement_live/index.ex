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
     |> assign(:new_transaction_account_id, nil)
     |> assign(:suggestion, nil)
     |> assign(:candidates, [])
     |> assign(:new_statement, nil)
     |> assign(:new_lines, [])
     |> assign(:new_error, nil)
     |> assign(:editing_total, nil)
     |> assign(:total_error, nil)
     |> assign(:search, "")
     |> assign(:card_filter, "")
     |> assign(:status_filter, "")
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
     |> assign(:new_transaction_account_id, nil)
     |> assign(:suggestion, nil)
     |> assign(:candidates, [])
     |> assign(:editing_total, nil)
     |> assign(:total_error, nil)}
  end

  @impl true
  def handle_event("new_statement", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_statement, %{
       "account_id" => "",
       "competencia" => "",
       "due_date" => "",
       "total_a_pagar" => ""
     })
     |> assign(:new_lines, [blank_line()])
     |> assign(:new_error, nil)}
  end

  def handle_event("close_new", _params, socket) do
    {:noreply, socket |> assign(:new_statement, nil) |> assign(:new_error, nil)}
  end

  def handle_event("edit_total", _params, socket) do
    {:noreply,
     socket
     |> assign(
       :editing_total,
       format_total_input(socket.assigns.selected.statement.total_a_pagar)
     )
     |> assign(:total_error, nil)}
  end

  def handle_event("cancel_total", _params, socket) do
    {:noreply, socket |> assign(:editing_total, nil) |> assign(:total_error, nil)}
  end

  def handle_event("save_total", %{"total_a_pagar" => raw}, socket) do
    case parse_total(raw) do
      {:ok, total} ->
        {:ok, _} =
          CreditCards.update_statement(socket.assigns.selected.statement, %{total_a_pagar: total})

        {:noreply,
         socket
         |> assign(:editing_total, nil)
         |> assign(:total_error, nil)
         |> load_statements()
         |> reload_selected()
         |> put_flash(:info, total_flash(total))}

      {:error, message} ->
        {:noreply, assign(socket, :total_error, message)}
    end
  end

  def handle_event("absorb_into", %{"target_id" => target_id}, socket) do
    statement = socket.assigns.selected.statement
    target = CreditCards.get_statement!(target_id)

    case CreditCards.absorb_into(statement, target) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Fatura incorporada!")
         |> load_statements()
         |> reload_selected()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, absorb_error(reason))}
    end
  end

  def handle_event("release_absorption", _params, socket) do
    {:ok, _} = CreditCards.release_absorption(socket.assigns.selected.statement)

    {:noreply,
     socket
     |> put_flash(:info, "Fatura desincorporada.")
     |> load_statements()
     |> reload_selected()}
  end

  def handle_event("attach_transaction", %{"id" => id}, socket) do
    statement = socket.assigns.selected.statement
    {:ok, count} = CreditCards.attach_transactions(statement, [id])

    {:noreply,
     socket
     |> put_flash(flash_kind(count), attach_message(count))
     |> load_statements()
     |> reload_selected()}
  end

  def handle_event("detach_transaction", %{"id" => id}, socket) do
    statement = socket.assigns.selected.statement
    {:ok, _count} = CreditCards.detach_transaction(statement, id)

    {:noreply,
     socket
     |> put_flash(:info, "Lançamento removido da fatura.")
     |> load_statements()
     |> reload_selected()}
  end

  def handle_event("add_line", _params, socket) do
    {:noreply, assign(socket, :new_lines, socket.assigns.new_lines ++ [blank_line()])}
  end

  def handle_event("remove_line", %{"index" => index}, socket) do
    i = String.to_integer(index)
    {:noreply, assign(socket, :new_lines, List.delete_at(socket.assigns.new_lines, i))}
  end

  def handle_event("validate_new", params, socket) do
    {:noreply,
     socket
     |> assign(
       :new_statement,
       Map.take(params, ~w(account_id competencia due_date total_a_pagar))
     )
     |> assign(:new_lines, lines_from_params(params))}
  end

  def handle_event("save_new", params, socket) do
    header = Map.take(params, ~w(account_id competencia due_date total_a_pagar))
    lines = lines_from_params(params)

    case build_manual_attrs(header) do
      {:error, message} ->
        {:noreply,
         socket
         |> assign(:new_statement, header)
         |> assign(:new_lines, lines)
         |> assign(:new_error, message)}

      {:ok, attrs} ->
        case CreditCards.create_manual_statement(attrs, build_manual_lines(lines)) do
          {:ok, _statement} ->
            {:noreply,
             socket
             |> assign(:new_statement, nil)
             |> assign(:new_error, nil)
             |> put_flash(:info, "Fatura criada.")
             |> load_statements()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:new_statement, header)
             |> assign(:new_lines, lines)
             |> assign(:new_error, "Não foi possível criar a fatura. Revise os valores.")}
        end
    end
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:search, params["search"] || "")
     |> assign(:card_filter, params["card"] || "")
     |> assign(:status_filter, params["status"] || "")
     |> apply_filters()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_statement, nil)
     |> assign(:new_lines, [])
     |> assign(:new_error, nil)
     |> assign(:search, "")
     |> assign(:card_filter, "")
     |> assign(:status_filter, "")
     |> apply_filters()}
  end

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
    # The card this statement belongs to, so the global "Nova Transação" button
    # opens on it: a charge typed from here always belongs to this card.
    |> assign(:new_transaction_account_id, detail.account.id)
    |> assign(:suggestion, suggestion)
    |> assign(:candidates, candidates)
    |> assign(:attachable, attachable_for(detail))
    |> assign(:absorption_targets, CreditCards.absorption_targets(detail.statement))
  end

  # Only a live cycle adopts loose purchases: an absorbed or already-paid
  # statement is settled history, and moving spend into it would change a total
  # that has been reconciled against the bank.
  defp attachable_for(%{lifecycle: lifecycle, statement: statement})
       when lifecycle in [:open, :closed],
       do: CreditCards.attachable_transactions(statement)

  defp attachable_for(_detail), do: []

  defp load_statements(socket) do
    entries = CreditCards.list_statements()
    card_groups = CreditCards.group_by_card(entries)

    socket
    |> assign(:entries, entries)
    # Kept apart from `entries`: the metrics, the gap report and the
    # reconciliation suggestions are all about statements that exist.
    |> assign(:pending, CreditCards.pending_cycles(entries))
    |> assign(:metrics, CreditCards.hub_metrics(entries))
    |> assign(:gaps, CreditCards.statement_gaps(entries))
    # Every credit-card account, not just those that already have a statement:
    # the whole point of "Nova fatura" is the card that has none.
    |> assign(:cards, CashLens.Accounts.list_credit_cards() |> Enum.sort_by(& &1.name))
    |> assign(:suggestions, current_suggestions(card_groups))
    |> assign(:unlinked_payments, CreditCards.unlinked_card_payments())
    |> apply_filters()
  end

  defp blank_line, do: %{"date" => "", "description" => "", "amount" => "", "kind" => "compra"}

  defp lines_from_params(params) do
    params
    |> Map.get("lines", %{})
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, line} -> line end)
  end

  # A statement needs the card and at least one of competência/vencimento --
  # `create_statement/1` keys its "already exists?" check on them, so without
  # either every save would create another row.
  defp build_manual_attrs(%{"account_id" => ""}), do: {:error, "Escolha o cartão."}

  defp build_manual_attrs(header) do
    competencia = parse_month(header["competencia"])
    due_date = parse_date(header["due_date"])

    if is_nil(competencia) and is_nil(due_date) do
      {:error, "Informe a competência ou o vencimento."}
    else
      {:ok,
       %{
         account_id: header["account_id"],
         competencia: competencia,
         due_date: due_date,
         total_a_pagar: parse_decimal(header["total_a_pagar"])
       }}
    end
  end

  defp build_manual_lines(lines) do
    lines
    |> Enum.map(fn line ->
      %{
        date: parse_date(line["date"]),
        description: String.trim(line["description"] || ""),
        amount: signed_amount(line)
      }
    end)
    |> Enum.filter(&(&1.date && &1.description != "" && &1.amount))
  end

  # The form asks what the line IS rather than making the operator remember
  # that a purchase is stored negative on a card.
  defp signed_amount(line) do
    case parse_decimal(line["amount"]) do
      nil ->
        nil

      value ->
        if line["kind"] == "credito",
          do: Decimal.abs(value),
          else: Decimal.negate(Decimal.abs(value))
    end
  end

  defp parse_month(value) when value in [nil, ""], do: nil

  defp parse_month(value) do
    case Date.from_iso8601(value <> "-01") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(value) when value in [nil, ""], do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # Blank is not zero. A `nil` total means "I do not know this bill yet", and
  # `card_occurrences/2` then projects the sum of the lines inside it; a number,
  # zero included, is taken as the bill itself. Collapsing the two is how a
  # hand-built statement ends up projected at R$ 0,00 no matter what it holds.
  defp parse_total(raw) do
    case String.trim(to_string(raw)) do
      "" ->
        {:ok, nil}

      trimmed ->
        case trimmed |> String.replace(".", "") |> String.replace(",", ".") |> Decimal.parse() do
          {decimal, ""} -> {:ok, decimal}
          _ -> {:error, "Valor inválido. Use por exemplo -112,28 ou 0."}
        end
    end
  end

  defp format_total_input(nil), do: ""
  defp format_total_input(%Decimal{} = total), do: total |> Decimal.to_string(:normal)

  defp total_flash(nil), do: "Total limpo: a fatura volta a valer a soma dos lançamentos."
  defp total_flash(total), do: "Total atualizado para #{format_currency(total)}."

  # Editing the total of a settled statement would move a number already
  # reconciled against the bank, the same reason absorption and attachment are
  # refused there.
  defp editable_total?(%{lifecycle: lifecycle}), do: lifecycle in [:open, :closed]

  defp parse_decimal(value) when value in [nil, ""], do: nil

  defp parse_decimal(value) do
    case value |> to_string() |> String.replace(",", ".") |> Decimal.parse() do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  # The table is filtered in memory: the whole statement list is already loaded
  # for the metrics and the gap scan, and it is tens of rows, not thousands.
  defp apply_filters(socket) do
    # The cycles still missing belong at the top, with the current month they
    # are part of -- which is where the descending order already puts it.
    visible =
      Enum.filter(socket.assigns.pending ++ socket.assigns.entries, &matches?(&1, socket.assigns))

    assign(socket, :visible_entries, visible)
  end

  defp matches?(entry, assigns) do
    matches_card?(entry, assigns.card_filter) and
      matches_status?(entry, assigns.status_filter) and
      matches_search?(entry, assigns.search)
  end

  defp matches_card?(_entry, ""), do: true
  defp matches_card?(entry, card_id), do: entry.account.id == card_id

  defp matches_status?(_entry, ""), do: true

  # One filter for both missing states: "sem fatura" is the question being
  # asked, and whether the cycle has closed is the row's own answer.
  defp matches_status?(entry, "pending"), do: entry.lifecycle in [:not_closed, :awaiting]
  defp matches_status?(entry, status), do: to_string(entry.lifecycle) == status

  # The month a row belongs to, statement or not. The zebra reads it, and so
  # does the search.
  defp cycle_of(%{statement: nil, competencia: competencia}), do: competencia
  defp cycle_of(%{statement: statement}), do: statement.competencia

  defp matches_search?(_entry, term) when term in [nil, ""], do: true

  defp matches_search?(entry, term) do
    needle = String.downcase(String.trim(term))
    statement = entry.statement

    [
      entry.account.name,
      entry.account.bank,
      statement && statement.source_file,
      format_competencia(cycle_of(entry)),
      statement && statement.due_date && Date.to_string(statement.due_date),
      entry.amount && Decimal.to_string(entry.amount),
      entry.payment && entry.payment.description,
      entry.payment && Decimal.to_string(entry.payment.amount)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(to_string(&1)), needle))
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

  # Pairs each row with whether its month's band is the shaded one. The flag
  # flips when the cycle changes, not every row, so a month reads as a block.
  defp striped_by_month(entries) do
    entries
    |> Enum.chunk_by(&cycle_of/1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {chunk, index} ->
      Enum.map(chunk, &{&1, rem(index, 2) == 1})
    end)
  end

  defp row_id(%{statement: nil, account: account}), do: "pending-row-#{account.id}"
  defp row_id(%{statement: statement}), do: "statement-row-#{statement.id}"

  defp lifecycle_badge(:open), do: {"badge-info", "Aberta"}
  defp lifecycle_badge(:closed), do: {"badge-warning", "Aguardando pagamento"}
  defp lifecycle_badge(:paid), do: {"badge-success", "Paga e conciliada"}
  defp lifecycle_badge(:absorbed), do: {"badge-ghost", "Incorporada"}
  defp lifecycle_badge(:not_closed), do: {"badge-ghost", "Ainda não fechou"}
  defp lifecycle_badge(:awaiting), do: {"badge-error badge-outline", "Aguardando fatura"}

  defp due_label(0), do: "hoje"
  defp due_label(1), do: "em 1 dia"
  defp due_label(days) when days < 0, do: "vencida há #{abs(days)} dias"
  defp due_label(days), do: "em #{days} dias"

  # A bill of zero, or one with a credit balance, has nothing to settle — an
  # absorbed cycle, or a month that closed owing nothing. Offering to reconcile a
  # payment against it only invites linking an unrelated debit.
  defp payable?(%{statement: %{total_a_pagar: %Decimal{} = total}}), do: Decimal.positive?(total)
  defp payable?(_selected), do: true

  attr :transactions, :list, required: true
  attr :detachable, :boolean, required: true

  # One table for the statement's own lines and for each absorbed cycle's. Only
  # the owning statement detaches a line: an absorbed cycle is reached through
  # its own screen, where detaching belongs.
  defp lines_table(assigns) do
    ~H"""
    <table :if={@transactions != []} class="table table-sm w-full text-xs">
      <thead>
        <tr>
          <th>Data</th>
          <th>Descrição</th>
          <th>Categoria</th>
          <th class="text-right">Valor</th>
          <th class="w-8"></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={t <- @transactions} class="hover">
          <td class="font-mono opacity-60 whitespace-nowrap">{format_date(t.date)}</td>
          <td>
            {t.description}
            <span :if={installment_label(t)} class="badge badge-ghost badge-xs ml-2">
              {installment_label(t)}
            </span>
          </td>
          <td>{t.category && t.category.name}</td>
          <td class="text-right font-mono font-black">{format_currency(t.amount)}</td>
          <td class="text-right w-8">
            <button
              :if={@detachable}
              type="button"
              id={"detach-#{t.id}"}
              phx-click="detach_transaction"
              phx-value-id={t.id}
              class="btn btn-ghost btn-xs text-error p-0"
              title="Remover da fatura"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp absorb_error(:same_statement), do: "Uma fatura não pode ser incorporada nela mesma."
  defp absorb_error(:different_account), do: "As duas faturas precisam ser do mesmo cartão."

  defp absorb_error(:target_absorbed),
    do: "A fatura escolhida já está incorporada em outra. Escolha a que de fato será cobrada."

  defp absorb_error(:target_earlier),
    do: "Uma fatura só pode ser incorporada em um ciclo posterior."

  defp absorb_error(_reason), do: "Não foi possível incorporar a fatura."

  defp flash_kind(0), do: :error
  defp flash_kind(_moved), do: :success

  defp attach_message(0),
    do: "Nada foi movido: o lançamento já pertence a outra fatura. Recarregue a tela."

  defp attach_message(_moved), do: "Lançamento incluído na fatura!"

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
    <span class={
      [
        "badge #{@class} badge-sm font-bold",
        # DaisyUI badges are a fixed height with no wrapping, so a long label spills
        # out of the pill and gets clipped. Let it grow instead.
        "h-auto whitespace-normal text-left leading-tight py-0.5"
      ]
    }>
      {@label}
    </span>
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
            <div :if={@metrics.next_due} class="text-xs opacity-50 mt-1 space-y-0.5">
              <p :for={s <- @metrics.next_due.statements} data-role="next-due-card">
                {s.account_name} · {format_currency(s.amount)}
              </p>
              <p
                :if={length(@metrics.next_due.statements) > 1}
                data-role="next-due-total"
                class="font-bold opacity-80 pt-0.5"
              >
                {length(@metrics.next_due.statements)} faturas · {format_currency(
                  @metrics.next_due.amount
                )}
              </p>
            </div>
            <div :if={is_nil(@metrics.next_due)} class="text-sm opacity-40 italic mt-2">
              Nenhuma fatura fechada a vencer.
            </div>
          </div>
        </div>

        <%!--
          Gaps worth acting on. Only two signals, both unambiguous: a month
          with no statement inside a card's own range, and a closed statement
          whose due date passed unpaid.
        --%>
        <div
          :if={@gaps.missing_months != [] or @gaps.overdue != []}
          data-role="statement-gaps"
          class="bg-warning/10 border border-warning/40 rounded-2xl px-6 py-4 space-y-2"
        >
          <h2 class="text-xs font-black uppercase tracking-wider">Lacunas</h2>

          <p :if={@gaps.missing_months != []} class="text-xs" data-role="gap-missing">
            <span class="font-bold">Sem fatura importada:</span>
            {Enum.map_join(@gaps.missing_months, " · ", fn m ->
              "#{m.account.name} #{format_competencia(m.competencia)}"
            end)}
          </p>

          <p :if={@gaps.overdue != []} class="text-xs" data-role="gap-overdue">
            <span class="font-bold">Vencida sem pagamento:</span>
            {Enum.map_join(@gaps.overdue, " · ", fn e ->
              "#{e.account.name} #{format_competencia(e.statement.competencia)} (#{format_currency(e.amount)})"
            end)}
          </p>
        </div>

        <div
          data-role="statements-table"
          class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden"
        >
          <div class="px-6 py-4 border-b border-base-300 space-y-3">
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="text-xs font-black uppercase tracking-wider">
                Faturas ({length(@visible_entries)}<span :if={
                  length(@visible_entries) != length(@entries)
                }> de {length(@entries)}</span>)
              </h2>
              <div class="flex items-center gap-2">
                <button
                  :if={@search != "" or @card_filter != "" or @status_filter != ""}
                  type="button"
                  phx-click="clear_filters"
                  class="btn btn-ghost btn-xs"
                >
                  Limpar filtros
                </button>
                <button type="button" phx-click="new_statement" class="btn btn-primary btn-xs">
                  <.icon name="hero-plus" class="size-3" /> Nova fatura
                </button>
              </div>
            </div>

            <form phx-change="filter" phx-submit="filter" class="flex flex-wrap gap-2">
              <input
                type="text"
                name="search"
                value={@search}
                phx-debounce="200"
                placeholder="Buscar por cartão, competência, valor, pagamento..."
                class="input input-bordered input-sm flex-1 min-w-[16rem]"
              />
              <select name="card" class="select select-bordered select-sm">
                <option value="">Todos os cartões</option>
                <option :for={card <- @cards} value={card.id} selected={@card_filter == card.id}>
                  {card.name}
                </option>
              </select>
              <select name="status" class="select select-bordered select-sm">
                <option value="">Todos os status</option>
                <option value="open" selected={@status_filter == "open"}>Aberta</option>
                <option value="closed" selected={@status_filter == "closed"}>Fechada</option>
                <option value="paid" selected={@status_filter == "paid"}>Paga</option>
                <option value="absorbed" selected={@status_filter == "absorbed"}>Incorporada</option>
                <option value="pending" selected={@status_filter == "pending"}>Sem fatura</option>
              </select>
            </form>
          </div>

          <p
            :if={@visible_entries == []}
            class="px-6 py-10 text-center text-sm opacity-40 italic"
          >
            Nenhuma fatura corresponde ao filtro.
          </p>

          <div class="overflow-x-auto">
            <table :if={@visible_entries != []} class="table table-sm">
              <thead>
                <tr class="text-[10px] uppercase">
                  <th>Cartão</th>
                  <th>Competência</th>
                  <th>Vencimento</th>
                  <th class="text-right">Total</th>
                  <th class="text-right">Linhas</th>
                  <th>Status</th>
                  <th>Pagamento</th>
                </tr>
              </thead>
              <tbody>
                <%!--
                  Striped by month rather than by row. The list runs several
                  cards deep per cycle, and alternating every line said nothing
                  about where one month ends and the next begins.
                --%>
                <tr
                  :for={{entry, shaded?} <- striped_by_month(@visible_entries)}
                  id={row_id(entry)}
                  class={[
                    "hover",
                    entry.statement && "cursor-pointer",
                    shaded? && "bg-base-200/50"
                  ]}
                  phx-click={entry.statement && JS.patch(~p"/statements?id=#{entry.statement.id}")}
                >
                  <td class="font-bold whitespace-nowrap">{entry.account.name}</td>
                  <td class="whitespace-nowrap">
                    {format_competencia(cycle_of(entry))}
                  </td>
                  <td class="whitespace-nowrap opacity-60">
                    {if entry.statement && entry.statement.due_date,
                      do: format_date(entry.statement.due_date),
                      else: "—"}
                  </td>
                  <td class="text-right font-mono font-bold whitespace-nowrap">
                    {if entry.amount, do: format_currency(entry.amount), else: "—"}
                  </td>
                  <td class="text-right opacity-50">{entry.line_count}</td>
                  <td><.badge lifecycle={entry.lifecycle} /></td>
                  <td class="text-xs">
                    <span :if={is_nil(entry.statement)} class="opacity-30 italic">—</span>
                    <div :if={entry.payment} class="whitespace-nowrap">
                      <span class="font-mono font-bold">
                        {format_currency(entry.payment.amount)}
                      </span>
                      <span class="opacity-40">
                        · {format_date(entry.payment.date)}
                      </span>
                      <p class="opacity-40 truncate max-w-[18rem]">
                        {entry.payment.description}
                      </p>
                    </div>
                    <div
                      :if={entry.statement && is_nil(entry.payment)}
                      class="flex items-center gap-2"
                    >
                      <button
                        :if={@suggestions[entry.statement.id]}
                        type="button"
                        phx-click="link"
                        phx-value-payment-id={@suggestions[entry.statement.id].id}
                        phx-value-statement-id={entry.statement.id}
                        class="btn btn-warning btn-xs"
                        title={"#{@suggestions[entry.statement.id].description} · #{format_currency(@suggestions[entry.statement.id].amount)}"}
                      >
                        <.icon name="hero-link" class="size-3" /> Conciliar
                      </button>
                      <span :if={is_nil(@suggestions[entry.statement.id])} class="opacity-30 italic">
                        —
                      </span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!--
          Typing a statement by hand. A bank app will not produce a PDF for a
          small or negative bill, which leaves its payment in the account with
          nothing to reconcile against.
        --%>
        <div
          :if={@new_statement}
          id="new-statement-modal"
          data-role="new-statement"
          class="modal modal-open"
          phx-window-keydown="close_new"
          phx-key="escape"
        >
          <div class="modal-box max-w-3xl">
            <h3 class="text-sm font-black uppercase tracking-tight">Nova fatura</h3>
            <p class="text-[11px] opacity-50 mt-0.5 mb-4">
              Registrada como <span class="font-mono">manual</span>. Se o pagamento já estiver
              lançado com o valor exato, ele é vinculado automaticamente.
            </p>

            <p :if={@new_error} class="alert alert-error text-xs mb-3">{@new_error}</p>

            <form phx-change="validate_new" phx-submit="save_new" class="space-y-4">
              <div class="grid grid-cols-1 sm:grid-cols-4 gap-3">
                <label class="form-control">
                  <span class="label-text text-xs">Cartão</span>
                  <select name="account_id" class="select select-bordered select-sm">
                    <option value="">Selecione</option>
                    <option
                      :for={card <- @cards}
                      value={card.id}
                      selected={@new_statement["account_id"] == card.id}
                    >
                      {card.name}
                    </option>
                  </select>
                </label>
                <label class="form-control">
                  <span class="label-text text-xs">Competência</span>
                  <input
                    type="month"
                    name="competencia"
                    value={@new_statement["competencia"]}
                    class="input input-bordered input-sm"
                  />
                </label>
                <label class="form-control">
                  <span class="label-text text-xs">Vencimento</span>
                  <input
                    type="date"
                    name="due_date"
                    value={@new_statement["due_date"]}
                    class="input input-bordered input-sm"
                  />
                </label>
                <label class="form-control">
                  <span class="label-text text-xs">Total da fatura</span>
                  <input
                    type="text"
                    name="total_a_pagar"
                    value={@new_statement["total_a_pagar"]}
                    placeholder="0,00"
                    class="input input-bordered input-sm"
                  />
                </label>
              </div>

              <div class="border-t border-base-200 pt-3">
                <div class="flex items-center justify-between mb-2">
                  <span class="text-xs font-black uppercase opacity-60">Lançamentos do ciclo</span>
                  <button type="button" phx-click="add_line" class="btn btn-ghost btn-xs">
                    <.icon name="hero-plus" class="size-3" /> Adicionar
                  </button>
                </div>

                <div class="space-y-2">
                  <div
                    :for={{line, index} <- Enum.with_index(@new_lines)}
                    class="grid grid-cols-12 gap-2 items-center"
                  >
                    <input
                      type="date"
                      name={"lines[#{index}][date]"}
                      value={line["date"]}
                      class="input input-bordered input-xs col-span-3"
                    />
                    <input
                      type="text"
                      name={"lines[#{index}][description]"}
                      value={line["description"]}
                      placeholder="Descrição"
                      class="input input-bordered input-xs col-span-4"
                    />
                    <select
                      name={"lines[#{index}][kind]"}
                      class="select select-bordered select-xs col-span-2"
                    >
                      <option value="compra" selected={line["kind"] != "credito"}>Compra</option>
                      <option value="credito" selected={line["kind"] == "credito"}>Crédito</option>
                    </select>
                    <input
                      type="text"
                      name={"lines[#{index}][amount]"}
                      value={line["amount"]}
                      placeholder="0,00"
                      class="input input-bordered input-xs col-span-2"
                    />
                    <button
                      type="button"
                      phx-click="remove_line"
                      phx-value-index={index}
                      class="btn btn-ghost btn-xs text-error col-span-1"
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </div>
                </div>
                <p class="text-[10px] opacity-40 mt-2">
                  Linhas sem data, descrição ou valor são ignoradas. O sinal é dado pelo tipo.
                </p>
              </div>

              <div class="flex gap-2 pt-2">
                <button type="submit" data-modal-default class="btn btn-primary btn-sm flex-1">
                  Criar fatura
                </button>
                <button type="button" phx-click="close_new" class="btn btn-ghost btn-sm">
                  Cancelar
                </button>
              </div>
            </form>
          </div>
          <div class="modal-backdrop bg-black/40" phx-click="close_new"></div>
        </div>

        <%!--
          The inverse of the reconcile flow: everything filed as a card payment
          that no statement claims. A row here is either a payment whose bill
          was never imported, or something categorized as a card payment that
          is not one — which is why the account is shown rather than filtered.
        --%>
        <div
          id="unlinked-payments"
          data-role="unlinked-payments"
          class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden"
        >
          <div class="px-6 py-4 border-b border-base-300">
            <h2 class="text-xs font-black uppercase tracking-wider">
              Sem fatura vinculada ({length(@unlinked_payments)})
            </h2>
            <p class="text-[11px] opacity-50 mt-0.5">
              Lançamentos na categoria Cartão de Crédito que nenhuma fatura reivindica.
            </p>
          </div>

          <p
            :if={@unlinked_payments == []}
            class="px-6 py-4 text-sm opacity-40 italic"
          >
            Nenhum lançamento solto.
          </p>

          <div class="divide-y divide-base-200">
            <div
              :for={tx <- @unlinked_payments}
              id={"unlinked-#{tx.id}"}
              class="px-6 py-2.5 flex flex-wrap items-center justify-between gap-2 text-xs"
            >
              <div class="min-w-0">
                <p class="font-bold truncate">{tx.description}</p>
                <p class="opacity-40">
                  {format_date(tx.date)} · {tx.account && tx.account.name}
                  <span :if={tx.account && tx.account.is_credit_card} class="text-warning font-bold">
                    · conta de cartão
                  </span>
                </p>
              </div>
              <span class={[
                "font-mono font-black whitespace-nowrap",
                if(Decimal.negative?(tx.amount), do: "text-error", else: "text-success")
              ]}>
                {format_currency(tx.amount)}
              </span>
            </div>
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
              <div :if={is_nil(@editing_total)} class="flex items-center justify-end gap-2">
                <p class="text-2xl font-black font-mono">{format_currency(@selected.amount)}</p>
                <button
                  :if={editable_total?(@selected)}
                  id="edit-total"
                  type="button"
                  phx-click="edit_total"
                  title="Editar total da fatura"
                  class="btn btn-ghost btn-xs p-1 min-h-0 h-6 opacity-50 hover:opacity-100"
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </button>
              </div>

              <form
                :if={@editing_total}
                id="total-form"
                phx-submit="save_total"
                class="flex items-center justify-end gap-2"
              >
                <input
                  type="text"
                  name="total_a_pagar"
                  value={@editing_total}
                  autocomplete="off"
                  placeholder="vazio = somar lançamentos"
                  class="input input-bordered input-sm w-48 text-right font-mono"
                />
                <button type="submit" class="btn btn-primary btn-sm">Salvar</button>
                <button type="button" phx-click="cancel_total" class="btn btn-ghost btn-sm">
                  Cancelar
                </button>
              </form>

              <p :if={@total_error} id="total-error" class="text-[11px] text-error mt-1">
                {@total_error}
              </p>
              <p :if={@editing_total} class="text-[10px] opacity-50 mt-1 max-w-xs">
                Aceita negativo. Em branco, a previsão passa a usar a soma dos lançamentos em vez
                de um total fixo.
              </p>

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

          <div
            :if={@selected.lifecycle == :absorbed}
            class="px-6 py-4 bg-base-200 flex flex-wrap items-center justify-between gap-3"
          >
            <div>
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
            <button
              type="button"
              id="release-absorption"
              phx-click="release_absorption"
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Desincorporar
            </button>
          </div>

          <%!--
            `absorb_pending/1` only folds a cycle in when the arithmetic proves
            it. Real statements often miss by a rounding difference or a credit
            the parser read as a line, and those have to be said by hand.
          --%>
          <div
            :if={@selected.lifecycle != :absorbed and @absorption_targets != []}
            id="absorb-into"
            class="px-6 py-4 border-t border-base-200"
          >
            <p class="text-xs font-bold uppercase opacity-60 mb-1">Incorporar em outra fatura</p>
            <p class="text-[11px] opacity-40 mb-2">
              Esta fatura deixa de ser cobrada por si e passa a contar dentro da escolhida.
            </p>
            <form phx-submit="absorb_into" class="flex flex-wrap items-center gap-2">
              <select
                name="target_id"
                class="select select-bordered select-sm rounded-lg text-xs flex-1 min-w-48"
              >
                <option :for={t <- @absorption_targets} value={t.id}>
                  {format_competencia(t.competencia)} · {format_currency(t.total_a_pagar)}
                </option>
              </select>
              <button type="submit" class="btn btn-warning btn-sm">Incorporar</button>
            </form>
          </div>

          <div
            :if={@selected.lifecycle in [:open, :closed] and payable?(@selected) and @suggestion}
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
            :if={@selected.lifecycle in [:open, :closed] and payable?(@selected)}
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
          <.lines_table transactions={@selected.transactions} detachable={true} />

          <%!--
            The cycles folded into this one, each under its own heading. This
            bill is what gets paid, so this screen is where someone looks to
            see what they are paying for; a flat list could not say which month
            a charge came from, and the absorbed months' lines appeared nowhere
            else but on screens the hub marks "Incorporada".
          --%>
          <div
            :for={group <- @selected.absorbed}
            id={"absorbed-group-#{group.statement.id}"}
            class="border-t-4 border-base-200"
          >
            <div class="px-6 py-3 bg-base-200/40 flex flex-wrap items-baseline justify-between gap-2">
              <p class="text-xs font-black uppercase tracking-tight flex items-baseline gap-2">
                <.icon name="hero-arrow-turn-down-right" class="size-4 opacity-50" />
                Incorporada · {format_competencia(group.statement.competencia)}
                <.link
                  patch={~p"/statements?id=#{group.statement.id}"}
                  class="link text-[11px] font-normal"
                >
                  ver fatura
                </.link>
              </p>
              <p class="font-mono font-black text-xs">
                {format_currency(group.amount || group.line_total)}
              </p>
            </div>
            <p
              :if={group.transactions == []}
              class="px-6 py-6 text-center opacity-40 text-sm"
            >
              Nenhum lançamento nesta fatura.
            </p>
            <.lines_table transactions={group.transactions} detachable={false} />
          </div>

          <%!--
            A purchase joins a statement through `import_batch_id`, which only an
            import or a manual statement sets. Anything that arrived by another
            route is stranded outside every bill until it is adopted here.
          --%>
          <div
            :if={editable_total?(@selected)}
            id="attachable-transactions"
            class="px-6 py-4 border-t border-base-200"
          >
            <p class="text-xs font-bold uppercase opacity-60 mb-1">Incluir lançamentos na fatura</p>
            <p class="text-[11px] opacity-40 mb-2">
              Compras deste cartão que não pertencem a nenhuma fatura.
            </p>
            <%!--
              Shown empty rather than hidden. Hiding it made the feature look
              absent: someone looking for where to add a purchase found no
              section at all and concluded the app could not do it.
            --%>
            <p :if={@attachable == []} class="text-sm opacity-40 italic">
              Nenhuma compra avulsa neste cartão.
            </p>
            <div class="divide-y divide-base-200 max-h-64 overflow-y-auto">
              <div
                :for={t <- @attachable}
                id={"attachable-#{t.id}"}
                class="py-2 flex flex-wrap items-center justify-between gap-2 text-xs"
              >
                <div class="min-w-0">
                  <p class="font-bold truncate">{t.description}</p>
                  <p class="opacity-40">
                    {format_date(t.date)} · {t.category && t.category.name}
                  </p>
                </div>
                <div class="flex items-center gap-3 shrink-0">
                  <span class="font-mono font-black">{format_currency(t.amount)}</span>
                  <button
                    type="button"
                    phx-click="attach_transaction"
                    phx-value-id={t.id}
                    class="btn btn-success btn-xs"
                  >
                    Incluir
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
