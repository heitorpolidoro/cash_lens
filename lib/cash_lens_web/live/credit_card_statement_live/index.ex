defmodule CashLensWeb.CreditCardStatementLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.CreditCards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Cartão de Crédito")
     |> assign(:filter_account_id, nil)
     |> assign(:only_open, false)
     |> assign(:selected, nil)
     |> assign(:suggestion, nil)
     |> load_statements()}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    detail = CreditCards.get_statement_detail(id)
    suggestion = detail.status == :open && CreditCards.suggest_payment(detail.statement)

    {:noreply,
     socket
     |> assign(:selected, detail)
     |> assign(:suggestion, suggestion)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
     |> assign(:suggestion, nil)}
  end

  @impl true
  def handle_event("filter", %{"account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id

    {:noreply,
     socket
     |> assign(:filter_account_id, account_id)
     |> filter_statements()}
  end

  @impl true
  def handle_event("toggle_only_open", _params, socket) do
    {:noreply,
     socket
     |> assign(:only_open, !socket.assigns.only_open)
     |> filter_statements()}
  end

  @impl true
  def handle_event("link", %{"payment-id" => payment_id}, socket) do
    statement = socket.assigns.selected.statement

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

  defp reload_selected(socket) do
    case socket.assigns.selected do
      nil ->
        socket

      %{statement: statement} ->
        detail = CreditCards.get_statement_detail(statement.id)
        suggestion = detail.status == :open && CreditCards.suggest_payment(detail.statement)

        socket
        |> assign(:selected, detail)
        |> assign(:suggestion, suggestion)
    end
  end

  defp load_statements(socket) do
    statements = CreditCards.list_statements()

    accounts =
      statements
      |> Enum.map(& &1.account)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.name)

    socket
    |> assign(:all_statements, statements)
    |> assign(:accounts, accounts)
    |> filter_statements()
  end

  defp filter_statements(socket) do
    %{filter_account_id: account_id, only_open: only_open, all_statements: statements} =
      socket.assigns

    filtered =
      statements
      |> Enum.filter(fn s -> is_nil(account_id) or s.account.id == account_id end)
      |> Enum.filter(fn s -> not only_open or s.status == :open end)

    assign(socket, :statements, filtered)
  end

  defp status_badge(:linked), do: {"badge-success", "✅", "Vinculada"}
  defp status_badge(:open), do: {"badge-warning", "⚠", "Aberta"}
  defp status_badge(:divergent), do: {"badge-error", "❗", "Divergente"}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8 max-w-4xl mx-auto">
      <div :if={is_nil(@selected)}>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-black uppercase tracking-tight">Cartão de Crédito</h1>
            <p class="text-xs opacity-50 mt-1">{length(@statements)} faturas</p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2 mb-4">
          <button
            class={"btn btn-xs #{if is_nil(@filter_account_id), do: "btn-primary", else: "btn-outline"}"}
            phx-click="filter"
            phx-value-account_id=""
          >
            Todos
          </button>
          <button
            :for={account <- @accounts}
            class={"btn btn-xs #{if @filter_account_id == account.id, do: "btn-primary", else: "btn-outline"}"}
            phx-click="filter"
            phx-value-account_id={account.id}
          >
            {account.name}
          </button>
          <button
            class={"btn btn-xs #{if @only_open, do: "btn-warning", else: "btn-outline"}"}
            phx-click="toggle_only_open"
          >
            Só abertas
          </button>
        </div>

        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
          <div :if={@statements == []} class="px-6 py-12 text-center opacity-40 text-sm">
            Nenhuma fatura encontrada.
          </div>
          <table :if={@statements != []} class="table table-sm w-full text-xs">
            <thead>
              <tr>
                <th>Cartão</th>
                <th>Competência</th>
                <th>Vence</th>
                <th class="text-right">Total a pagar</th>
                <th class="text-right">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={s <- @statements}
                class="hover cursor-pointer"
                phx-click={JS.patch(~p"/statements?id=#{s.statement.id}")}
              >
                <td>{s.account && s.account.name}</td>
                <td>{format_competencia(s.statement.competencia)}</td>
                <td>{format_date(s.statement.due_date)}</td>
                <td class="text-right font-mono font-black">
                  {format_currency(s.statement.total_a_pagar || s.line_total)}
                </td>
                <td class="text-right">
                  <% {badge_class, emoji, label} = status_badge(s.status) %>
                  <span class={"badge #{badge_class} badge-sm gap-1"}>
                    {emoji} {label}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@selected}>
        <div class="flex items-center justify-between mb-6">
          <.link patch={~p"/statements"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Voltar
          </.link>
        </div>

        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden mb-6">
          <div class="px-6 py-4 border-b border-base-300 flex items-start justify-between">
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
            </div>
            <div class="text-right">
              <p class="text-2xl font-black font-mono">
                {format_currency(@selected.statement.total_a_pagar || @selected.line_total)}
              </p>
              <p class="text-[10px] opacity-50 mt-1">
                Soma dos lançamentos: {format_currency(@selected.line_total)}
              </p>
            </div>
          </div>

          <div
            :if={@selected.status != :open}
            class={[
              "px-6 py-4 flex items-center justify-between",
              if(@selected.status == :linked, do: "bg-success/10", else: "bg-error/10")
            ]}
          >
            <div>
              <p class="text-xs font-bold uppercase opacity-60">
                {if @selected.status == :linked, do: "Pagamento vinculado", else: "Vínculo divergente"}
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

          <div :if={@selected.status == :open} class="px-6 py-4 bg-warning/10">
            <p class="text-xs font-bold uppercase opacity-60 mb-2">Fatura em aberto</p>
            <div :if={@suggestion} class="flex items-center justify-between">
              <div>
                <p class="text-[10px] opacity-50">Sugestão de pagamento</p>
                <p class="font-black">
                  {@suggestion.description}
                  <span class="opacity-50 font-normal">
                    ({format_date(@suggestion.date)} · {@suggestion.account &&
                      @suggestion.account.name})
                  </span>
                </p>
                <p class="font-mono font-black">{format_currency(@suggestion.amount)}</p>
              </div>
              <button
                class="btn btn-success btn-sm"
                phx-click="link"
                phx-value-payment-id={@suggestion.id}
              >
                <.icon name="hero-link" class="size-4" /> Vincular
              </button>
            </div>
            <p :if={is_nil(@suggestion)} class="text-sm opacity-40 italic">
              Nenhuma sugestão de pagamento encontrada.
            </p>
          </div>
        </div>

        <div class="bg-base-100 rounded-2xl border border-base-300 shadow-sm overflow-hidden">
          <div class="px-6 py-4 border-b border-base-300">
            <h2 class="font-black uppercase tracking-tight text-sm">Lançamentos</h2>
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
                <td>{t.description}</td>
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
