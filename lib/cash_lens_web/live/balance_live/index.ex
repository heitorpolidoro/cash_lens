defmodule CashLensWeb.BalanceLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting
  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Histórico de Saldos
        <:subtitle>
          Revise seus saldos mensais históricos. Estes são calculados com base no saldo inicial da conta e nas transações.
        </:subtitle>
        <:actions>
          <button phx-click="recalculate_all" class="btn btn-outline btn-warning btn-sm">
            <.icon name="hero-arrow-path-rounded-square" class="mr-1" /> Recalcular Tudo
          </button>
        </:actions>
      </.header>

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <form id="filter-form" phx-change="filter">
          <table class="table table-zebra w-full text-xs">
            <thead class="bg-base-200/50">
              <tr>
                <th class="w-48">
                  <div class="flex flex-col gap-1">
                    <span>Conta</span>
                    <select
                      name="account_id"
                      class="select select-bordered select-xs font-normal w-full"
                    >
                      <option value="">Todas</option>
                      <%= for account <- @accounts do %>
                        <option value={account.id} selected={@filters["account_id"] == account.id}>
                          {account_label(account)}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-24">
                  <div class="flex flex-col gap-1">
                    <span>Ano</span>
                    <select name="year" class="select select-bordered select-xs font-normal w-full">
                      <option value="">Todos</option>
                      <%= for year <- 2024..2030 do %>
                        <option value={year} selected={@filters["year"] == to_string(year)}>
                          {year}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="w-32">
                  <div class="flex flex-col gap-1">
                    <span>Mês</span>
                    <select name="month" class="select select-bordered select-xs font-normal w-full">
                      <option value="">Todos</option>
                      <%= for {name, num} <- month_options() do %>
                        <option value={num} selected={@filters["month"] == to_string(num)}>
                          {name}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Saldo Inicial</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Receitas</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1">
                    <span>Despesas</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="text-right">
                  <div class="flex flex-col gap-1 font-black">
                    <span>Saldo Final</span>
                    <div class="h-6"></div>
                  </div>
                </th>
                <th class="w-16 text-center">
                  <div class="flex flex-col gap-1 items-center">
                    <span class="opacity-0">Reset</span>
                    <button
                      type="button"
                      phx-click="clear_filters"
                      class="btn btn-ghost btn-xs text-error p-0"
                      title="Clear filters"
                    >
                      <.icon name="hero-x-circle" class="size-4" />
                    </button>
                  </div>
                </th>
              </tr>
            </thead>
            <tbody id="balances" phx-update="stream">
              <tr
                :for={{id, balance} <- @streams.balances}
                id={id}
                class="hover group border-b border-base-200"
              >
                <td>
                  <div class="flex items-center gap-3">
                    <div class="avatar placeholder text-[10px]">
                      <div class="w-8 rounded-full bg-base-300">
                        <%= if balance.account && balance.account.icon && balance.account.icon != "" do %>
                          <img src={balance.account.icon} />
                        <% else %>
                          <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content font-bold uppercase">
                            {if balance.account,
                              do: String.slice(balance.account.bank || balance.account.name, 0..1),
                              else: "?"}
                          </div>
                        <% end %>
                      </div>
                    </div>
                    <span class="font-bold truncate max-w-[120px]">
                      {if balance.account, do: balance.account.name, else: "Conta excluída"}
                    </span>
                  </div>
                </td>
                <td class="opacity-70">{balance.year}</td>
                <td>{translate_month_num(balance.month)}</td>
                <td class="text-right opacity-70">{format_currency(balance.initial_balance)}</td>
                <td class="text-right text-success font-medium">{format_currency(balance.income)}</td>
                <td class="text-right text-error font-medium">{format_currency(balance.expenses)}</td>
                <td class="text-right font-black bg-base-200/30">
                  {format_currency(balance.final_balance)}
                </td>

                <td class="text-right opacity-40 italic">
                  Somente leitura
                </td>
              </tr>
            </tbody>
          </table>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Saldos")
     |> assign(:accounts, Accounts.list_accounts())
     |> assign(:filters, %{"account_id" => "", "month" => "", "year" => ""})
     |> stream(:balances, Accounting.list_balances())}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filters, params)
     |> stream(:balances, Accounting.list_balances(params), reset: true)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = %{"account_id" => "", "month" => "", "year" => ""}

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> stream(:balances, Accounting.list_balances(filters), reset: true)}
  end

  @impl true
  def handle_event("recalculate_all", _params, socket) do
    Accounting.recalculate_all_balances()

    {:noreply,
     socket
     |> put_flash(:success, "Todos os saldos foram recalculados em cascata!")
     |> stream(:balances, Accounting.list_balances(socket.assigns.filters), reset: true)}
  end

  defp translate_month_num(num) do
    Enum.at(
      ["Jan", "Fev", "Mar", "Abr", "Mai", "Jun", "Jul", "Ago", "Set", "Out", "Nov", "Dez"],
      num - 1
    )
  end

  defp month_options do
    [
      {"Janeiro", 1},
      {"Fevereiro", 2},
      {"Março", 3},
      {"Abril", 4},
      {"Maio", 5},
      {"Junho", 6},
      {"Julho", 7},
      {"Agosto", 8},
      {"Setembro", 9},
      {"Outubro", 10},
      {"Novembro", 11},
      {"Dezembro", 12}
    ]
  end
end
