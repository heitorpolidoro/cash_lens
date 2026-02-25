defmodule CashLensWeb.BalanceLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Listando Balanços
      <:actions>
        <.link navigate={~p"/balances/new"}>
          <.button variant="primary">
            <.icon name="hero-plus" class="mr-1" /> Novo Balanço
          </.button>
        </.link>
      </:actions>
    </.header>

    <.table
      id="balances"
      rows={@streams.balances}
      row_click={fn {_id, balance} -> JS.navigate(~p"/balances/#{balance}") end}
    >
      <:col :let={{_id, balance}} label="Conta">
        <div class="flex items-center gap-3">
          <div class="avatar placeholder">
            <div class="w-8 rounded-full bg-base-300">
              <%= if balance.account && balance.account.icon && balance.account.icon != "" do %>
                <img src={balance.account.icon} />
              <% else %>
                <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content text-[10px] font-bold uppercase">
                  {if balance.account, do: String.slice(balance.account.bank || balance.account.name, 0..1), else: "?"}
                </div>
              <% end %>
            </div>
          </div>
          <span class="font-bold">{if balance.account, do: balance.account.name, else: "Conta excluída"}</span>
        </div>
      </:col>
      <:col :let={{_id, balance}} label="Ano">{balance.year}</:col>
      <:col :let={{_id, balance}} label="Mês">{balance.month}</:col>
      <:col :let={{_id, balance}} label="Saldo Inicial">{format_currency(balance.initial_balance)}</:col>
      <:col :let={{_id, balance}} label="Entradas">{format_currency(balance.income)}</:col>
      <:col :let={{_id, balance}} label="Saídas">{format_currency(balance.expenses)}</:col>
      <:col :let={{_id, balance}} label="Balanço">
        <span class={if Decimal.lt?(balance.balance, 0), do: "text-error", else: "text-success"}>
          {format_currency(balance.balance)}
        </span>
      </:col>
      <:col :let={{_id, balance}} label="Saldo Final">{format_currency(balance.final_balance)}</:col>
      <:action :let={{_id, balance}}>
        <div class="sr-only">
          <.link navigate={~p"/balances/#{balance}"}>Exibir</.link>
        </div>
        <.link navigate={~p"/balances/#{balance}/edit"}>Editar</.link>
      </:action>
      <:action :let={{id, balance}}>
        <.link
          phx-click={JS.push("delete", value: %{id: balance.id}) |> hide("##{id}")}
          data-confirm="Tem certeza?"
        >
          Excluir
        </.link>
      </:action>
    </.table>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Balanços")
     |> stream(:balances, list_balances())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    balance = Accounting.get_balance!(id)
    {:ok, _} = Accounting.delete_balance(balance)

    {:noreply, stream_delete(socket, :balances, balance)}
  end

  defp list_balances() do
    Accounting.list_balances()
  end
end
