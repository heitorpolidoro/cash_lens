defmodule CashLensWeb.BalanceLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounting

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
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
            <div class="avatar placeholder text-[10px]">
              <div class="w-8 rounded-full bg-base-300">
                <%= if balance.account && balance.account.icon && balance.account.icon != "" do %>
                  <img src={balance.account.icon} />
                <% else %>
                  <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content font-bold uppercase">
                    {if balance.account, do: String.slice(balance.account.bank || balance.account.name, 0..1), else: "?"}
                  </div>
                <% end %>
              </div>
            </div>
            <span class="font-bold">{if balance.account, do: balance.account.name, else: "Conta excluída"}</span>
          </div>
        </:col>
        <:col :let={{_id, balance}} label="Ano">{balance.year}</:col>
        <:col :let={{_id, balance}} label="Mês">{translate_month_num(balance.month)}</:col>
        <:col :let={{_id, balance}} label="Entradas">{format_currency(balance.income)}</:col>
        <:col :let={{_id, balance}} label="Saídas">{format_currency(balance.expenses)}</:col>
        <:col :let={{_id, balance}} label="Saldo Final" class="font-black text-right">{format_currency(balance.final_balance)}</:col>
        
        <:action :let={{_id, balance}}>
          <div class="flex gap-2">
            <.link navigate={~p"/balances/#{balance}/edit"} class="btn btn-ghost btn-xs">Editar</.link>
            <button phx-click="confirm_delete" phx-value-id={balance.id} class="btn btn-ghost btn-xs text-error">Excluir</button>
          </div>
        </:action>
      </.table>
    </div>

    <!-- Modal de Confirmação -->
    <.modal :if={@confirm_modal} id="confirm-modal" show on_cancel={JS.push("close_modal")}>
      <div class="p-4 text-center">
        <div class="w-20 h-20 bg-error/10 text-error rounded-full flex items-center justify-center mx-auto mb-6">
          <.icon name="hero-trash" class="size-10" />
        </div>
        <h2 class="text-2xl font-black mb-2">Excluir Balanço?</h2>
        <p class="text-base-content/60 mb-10">Deseja realmente apagar este registro de balanço mensal?</p>
        <div class="flex flex-col sm:flex-row gap-3">
          <button phx-click={@confirm_modal.action} class="btn btn-error btn-lg flex-1 rounded-2xl">Sim, Apagar</button>
          <button phx-click="close_modal" class="btn btn-ghost btn-lg flex-1 rounded-2xl">Cancelar</button>
        </div>
      </div>
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Balanços")
     |> assign(:confirm_modal, nil)
     |> stream(:balances, Accounting.list_balances())}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    confirm = %{action: JS.push("delete", value: %{id: id})}
    {:noreply, assign(socket, :confirm_modal, confirm)}
  end

  @impl true
  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, :confirm_modal, nil)}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    balance = Accounting.get_balance!(id)
    {:ok, _} = Accounting.delete_balance(balance)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:balances, balance)}
  end

  defp translate_month_num(num) do
    Enum.at(["Jan", "Fev", "Mar", "Abr", "Mai", "Jun", "Jul", "Ago", "Set", "Out", "Nov", "Dez"], num - 1)
  end
end
