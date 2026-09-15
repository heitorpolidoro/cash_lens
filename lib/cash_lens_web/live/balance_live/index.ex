defmodule CashLensWeb.BalanceLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounting.BalanceAdjuster
  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-6">
      <.header>
        Histórico de Saldos
        <:subtitle>
          Fechamento contábil e conciliação mês a mês por conta.
        </:subtitle>
      </.header>

      <div id="balance-filters" class="bg-base-100 rounded-2xl border border-base-300 p-4 shadow-sm">
        <form id="filter-form" phx-change="filter">
          <div class="grid grid-cols-1 sm:grid-cols-4 gap-4 items-end">
            <div class="flex flex-col gap-1">
              <label class="text-xs font-bold uppercase tracking-wider opacity-60">Ano</label>
              <select name="year" class="select select-bordered select-sm w-full">
                <option value="">Todos os anos</option>
                <option
                  :for={year <- year_options()}
                  value={year}
                  selected={@filters["year"] == to_string(year)}
                >
                  {year}
                </option>
              </select>
            </div>

            <div class="flex flex-col gap-1">
              <label class="text-xs font-bold uppercase tracking-wider opacity-60">Mês</label>
              <select name="month" class="select select-bordered select-sm w-full">
                <option value="">Todos os meses</option>
                <option
                  :for={{name, num} <- month_options()}
                  value={num}
                  selected={@filters["month"] == to_string(num)}
                >
                  {name}
                </option>
              </select>
            </div>

            <div class="flex flex-col gap-1">
              <label class="text-xs font-bold uppercase tracking-wider opacity-60">Conta</label>
              <select name="account_id" class="select select-bordered select-sm w-full">
                <option value="">Todas as contas</option>
                <option
                  :for={account <- @accounts}
                  value={account.id}
                  selected={@filters["account_id"] == to_string(account.id)}
                >
                  {account_label(account)}
                </option>
              </select>
            </div>

            <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm rounded-xl">
              Limpar Filtros
            </button>
          </div>
        </form>
      </div>

      <p class="text-xs opacity-60 px-1">
        Clique em qualquer linha para abrir o extrato da conta. Clique no lápis para ajustar o saldo
        final sem abrir o extrato.
      </p>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th class="w-48">Conta</th>
              <th class="w-28">Período</th>
              <th class="text-right">Saldo Inicial</th>
              <th class="text-right text-success">Receitas</th>
              <th class="text-right text-error">Despesas</th>
              <th class="text-right text-info">Transf. Entrada</th>
              <th class="text-right text-warning">Transf. Saída</th>
              <th class="text-right font-black">Saldo Final</th>
              <th class="w-8"></th>
            </tr>
          </thead>
          <tbody id="balances" phx-update="stream">
            <tr
              :for={{id, balance} <- @streams.balances}
              id={id}
              phx-click="open_statement"
              phx-value-account_id={balance.account_id}
              phx-value-year={balance.year}
              phx-value-month={balance.month}
              class="hover group border-b border-base-200 cursor-pointer"
            >
              <td>
                <div class="flex items-center gap-3">
                  <div class="avatar placeholder text-[10px]">
                    <div class="w-8 rounded-full bg-base-300">
                      <%= if balance.account && balance.account.icon && balance.account.icon != "" do %>
                        <img src={balance.account.icon} />
                      <% else %>
                        <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content font-bold uppercase">
                          {account_initials(balance.account)}
                        </div>
                      <% end %>
                    </div>
                  </div>
                  <span class="font-bold truncate max-w-[120px]">
                    {if balance.account, do: balance.account.name, else: "Conta excluída"}
                  </span>
                </div>
              </td>
              <td class="font-semibold opacity-70">
                {month_abbreviation(balance.month)} / {balance.year}
              </td>
              <td class="text-right opacity-70">{format_currency(balance.initial_balance)}</td>
              <td class="text-right text-success font-medium">{format_currency(balance.income)}</td>
              <td class="text-right text-error font-medium">-{format_currency(balance.expenses)}</td>
              <td class="text-right text-info/80">
                {format_transfer(balance.transfers_in)}
              </td>
              <td class="text-right text-warning/80">
                {format_transfer(balance.transfers_out)}
              </td>
              <td class="text-right font-black bg-base-200/30">
                <div class="flex items-center justify-end gap-2">
                  <span>{format_currency(balance.final_balance)}</span>
                  <%!-- LiveView dispatches only the innermost phx-click binding, so this button
                        never triggers the row's "open_statement" navigation. --%>
                  <button
                    type="button"
                    phx-click="open_adjust"
                    phx-value-account_id={balance.account_id}
                    phx-value-year={balance.year}
                    phx-value-month={balance.month}
                    class="btn btn-ghost btn-xs px-1"
                    title="Ajustar saldo desta conta"
                  >
                    <.icon name="hero-pencil" class="size-3.5" />
                  </button>
                </div>
              </td>
              <td class="text-right opacity-30 group-hover:opacity-100">
                <.icon name="hero-chevron-right" class="size-4" />
              </td>
            </tr>
          </tbody>
          <tfoot class="bg-primary/5 border-t-2 border-base-300 font-black">
            <tr id="balances-totals">
              <td class="uppercase tracking-wider text-[11px]">
                TOTAL CONSOLIDADO ({@totals.count} contas)
              </td>
              <td></td>
              <td class="text-right">{format_currency(@totals.initial_balance)}</td>
              <td class="text-right text-success">{format_currency(@totals.income)}</td>
              <td class="text-right text-error">-{format_currency(@totals.expenses)}</td>
              <td class="text-right text-info">{format_currency(@totals.transfers_in)}</td>
              <td class="text-right text-warning">-{format_currency(@totals.transfers_out)}</td>
              <td class="text-right text-primary text-sm bg-primary/10">
                {format_currency(@totals.final_balance)}
              </td>
              <td></td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>

    <.modal
      :if={@adjust_modal}
      id="adjust-balance-modal"
      show
      on_cancel={JS.push("close_adjust")}
    >
      <div class="space-y-5">
        <div>
          <h2 class="text-2xl font-black">Ajustar Saldo Final</h2>
          <p class="text-sm opacity-60">
            {@adjust_modal.account_name} — {month_name(@adjust_modal.month)}/{@adjust_modal.year}
          </p>
        </div>

        <div class="grid grid-cols-2 gap-3 bg-base-200/60 rounded-2xl p-4 text-sm">
          <div>
            <span class="block text-xs opacity-60 font-semibold">Saldo Calculado Atual</span>
            <span class="font-extrabold">{format_currency(@adjust_modal.current_balance)}</span>
          </div>
          <div>
            <span class="block text-xs opacity-60 font-semibold">Diferença a Lançar</span>
            <span class={["font-extrabold", difference_class(@adjust_diff)]}>
              {format_difference(@adjust_diff)}
            </span>
          </div>
        </div>

        <.form
          for={@adjust_form}
          id="adjust-form"
          phx-change="validate_adjust"
          phx-submit="apply_adjust"
        >
          <label class="block text-xs font-bold uppercase tracking-wider opacity-70 mb-1.5">
            Saldo Real no Banco (Extrato Oficial)
          </label>
          <input
            type="number"
            step="0.01"
            name="adjust[real_balance]"
            value={@adjust_form.params["real_balance"]}
            class="input input-bordered w-full font-bold"
          />
          <p :if={@adjust_error} class="text-error text-xs mt-1">{@adjust_error}</p>

          <span class="block text-xs font-bold uppercase tracking-wider opacity-70 mt-5 mb-2">
            Tipo de Ajuste
          </span>

          <label class="flex items-start gap-3 p-3 rounded-2xl border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="adjust[adjust_type]"
              value="rendimento"
              checked={@adjust_form.params["adjust_type"] != "correcao"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span>
              <span class="font-bold text-sm block">Rendimento do Mês</span>
              <span class="text-xs opacity-60 block">
                Cria uma transação de receita na categoria "Rendimentos" no último dia do mês com o
                valor da diferença.
              </span>
            </span>
          </label>

          <label class="flex items-start gap-3 p-3 mt-2 rounded-2xl border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="adjust[adjust_type]"
              value="correcao"
              checked={@adjust_form.params["adjust_type"] == "correcao"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span>
              <span class="font-bold text-sm block">Correção de Saldo Inicial Histórico</span>
              <span class="text-xs opacity-60 block">
                Aplica a diferença no primeiro saldo de abertura desta conta e recalcula toda a
                cadeia histórica de meses.
              </span>
            </span>
          </label>

          <div class="flex gap-3 mt-6">
            <button type="submit" class="btn btn-primary flex-1 rounded-2xl">
              Aplicar Ajuste
            </button>
            <button
              type="button"
              phx-click="close_adjust"
              class="btn btn-ghost flex-1 rounded-2xl"
            >
              Cancelar
            </button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    filters = %{
      "account_id" => "",
      "month" => to_string(today.month),
      "year" => to_string(today.year)
    }

    {:ok,
     socket
     |> assign(:page_title, "Saldos")
     |> assign(:accounts, Accounts.list_accounts())
     |> assign(:filters, filters)
     |> close_adjust_modal()
     |> load_balances(filters)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = Map.take(params, ["account_id", "month", "year"])

    {:noreply, socket |> assign(:filters, filters) |> load_balances(filters)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"account_id" => "", "month" => "", "year" => ""}

    {:noreply, socket |> assign(:filters, filters) |> load_balances(filters)}
  end

  @impl true
  def handle_event("open_statement", params, socket) do
    %{"account_id" => account_id, "year" => year, "month" => month} = params

    {:noreply,
     push_navigate(socket,
       to: ~p"/transactions?account_id=#{account_id}&year=#{year}&month=#{month}"
     )}
  end

  @impl true
  def handle_event("open_adjust", params, socket) do
    %{"account_id" => account_id, "year" => year, "month" => month} = params
    year = to_integer(year)
    month = to_integer(month)

    case BalanceAdjuster.current_final_balance(account_id, year, month) do
      nil ->
        {:noreply, put_flash(socket, :error, "Saldo não encontrado para o período.")}

      current_balance ->
        {:noreply, open_adjust_modal(socket, account_id, year, month, current_balance)}
    end
  end

  @impl true
  def handle_event("close_adjust", _params, socket) do
    {:noreply, close_adjust_modal(socket)}
  end

  @impl true
  def handle_event("validate_adjust", %{"adjust" => params}, socket) do
    {:noreply, assign_adjust_params(socket, params)}
  end

  @impl true
  def handle_event("apply_adjust", %{"adjust" => params}, socket) do
    socket = assign_adjust_params(socket, params)
    modal = socket.assigns.adjust_modal

    case parse_decimal(params["real_balance"]) do
      :error ->
        {:noreply, assign(socket, :adjust_error, "Informe o saldo real do extrato.")}

      {:ok, real_balance} ->
        result =
          BalanceAdjuster.adjust_final_balance(
            modal.account_id,
            modal.year,
            modal.month,
            real_balance,
            parse_adjust_type(params["adjust_type"])
          )

        {:noreply, handle_adjust_result(socket, result)}
    end
  end

  defp handle_adjust_result(socket, {:ok, :rendimento}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:success, "Rendimento registrado com sucesso.")
  end

  defp handle_adjust_result(socket, {:ok, :correcao}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:success, "Saldo inicial corrigido e histórico recalculado.")
  end

  defp handle_adjust_result(socket, {:error, :no_difference}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:info, "Nenhuma diferença a registrar.")
  end

  defp handle_adjust_result(socket, {:error, :category_not_found}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:error, "Categoria Rendimento não encontrada.")
  end

  defp handle_adjust_result(socket, {:error, :duplicate}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:error, "Já existe uma transação idêntica registrada.")
  end

  defp handle_adjust_result(socket, {:error, :balance_not_found}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:error, "Saldo não encontrado para o período.")
  end

  defp handle_adjust_result(socket, {:error, _reason}) do
    socket
    |> reload_after_adjust()
    |> put_flash(:error, "Não foi possível aplicar o ajuste.")
  end

  defp reload_after_adjust(socket) do
    socket
    |> close_adjust_modal()
    |> load_balances(socket.assigns.filters)
  end

  defp open_adjust_modal(socket, account_id, year, month, current_balance) do
    account = Accounts.get_account!(account_id)

    params = %{
      "real_balance" => Decimal.to_string(Decimal.round(current_balance, 2), :normal),
      "adjust_type" => "rendimento"
    }

    socket
    |> assign(:adjust_modal, %{
      account_id: account_id,
      account_name: account.name,
      year: year,
      month: month,
      current_balance: current_balance
    })
    |> assign_adjust_params(params)
  end

  defp close_adjust_modal(socket) do
    socket
    |> assign(:adjust_modal, nil)
    |> assign(:adjust_form, to_form(%{}, as: :adjust))
    |> assign(:adjust_diff, Decimal.new(0))
    |> assign(:adjust_error, nil)
  end

  defp assign_adjust_params(socket, params) do
    current = socket.assigns.adjust_modal[:current_balance] || Decimal.new(0)

    diff =
      case parse_decimal(params["real_balance"]) do
        {:ok, real_balance} -> Decimal.sub(real_balance, current)
        :error -> Decimal.new(0)
      end

    socket
    |> assign(:adjust_form, to_form(params, as: :adjust))
    |> assign(:adjust_diff, diff)
    |> assign(:adjust_error, nil)
  end

  defp load_balances(socket, filters) do
    balances = Accounting.list_balances(filters)

    socket
    |> assign(:totals, calculate_totals(balances))
    |> stream(:balances, balances, reset: true)
  end

  defp calculate_totals(balances) do
    Enum.reduce(balances, empty_totals(), fn balance, totals ->
      %{
        count: totals.count + 1,
        initial_balance: Decimal.add(totals.initial_balance, balance.initial_balance),
        income: Decimal.add(totals.income, balance.income),
        expenses: Decimal.add(totals.expenses, balance.expenses),
        transfers_in: Decimal.add(totals.transfers_in, balance.transfers_in),
        transfers_out: Decimal.add(totals.transfers_out, balance.transfers_out),
        final_balance: Decimal.add(totals.final_balance, balance.final_balance)
      }
    end)
  end

  defp empty_totals do
    zero = Decimal.new(0)

    %{
      count: 0,
      initial_balance: zero,
      income: zero,
      expenses: zero,
      transfers_in: zero,
      transfers_out: zero,
      final_balance: zero
    }
  end

  defp parse_decimal(nil), do: :error
  defp parse_decimal(""), do: :error

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(String.replace(value, ",", ".")) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp parse_adjust_type("correcao"), do: :correcao
  defp parse_adjust_type(_), do: :rendimento

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  defp account_initials(nil), do: "?"

  defp account_initials(account) do
    String.slice(account.bank || account.name, 0..1)
  end

  defp format_transfer(nil), do: "—"

  defp format_transfer(value) do
    if Decimal.gt?(value, 0), do: format_currency(value), else: "—"
  end

  defp format_difference(diff) do
    cond do
      Decimal.gt?(diff, 0) -> "+#{format_currency(diff)}"
      Decimal.lt?(diff, 0) -> format_currency(diff)
      true -> format_currency(diff)
    end
  end

  defp difference_class(diff) do
    cond do
      Decimal.gt?(diff, 0) -> "text-success"
      Decimal.lt?(diff, 0) -> "text-error"
      true -> "opacity-60"
    end
  end

  defp month_abbreviation(num), do: num |> month_label() |> String.capitalize()

  defp month_options, do: Enum.map(1..12, fn num -> {month_name(num), num} end)

  defp year_options do
    current_year = Date.utc_today().year
    Enum.to_list((current_year + 1)..(current_year - 6)//-1)
  end
end
