defmodule CashLensWeb.AccountLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Listando Contas
        <:actions>
          <.link navigate={~p"/accounts/new"}>
            <.button variant="primary">
              <.icon name="hero-plus" class="mr-1" /> Nova Conta
            </.button>
          </.link>
        </:actions>
      </.header>

      <.table
        id="accounts"
        rows={@streams.accounts}
        row_click={fn {_id, account} -> JS.navigate(~p"/accounts/#{account}") end}
      >
        <:col :let={{_id, account}} label="Ícone">
          <div class="avatar">
            <div class="w-8 rounded-full bg-base-300">
              <%= if account.icon && account.icon != "" do %>
                <img src={account.icon} />
              <% else %>
                <div class="flex items-center justify-center h-full w-full bg-primary text-primary-content text-[10px] font-bold uppercase">
                  {String.slice(account.bank || account.name, 0..1)}
                </div>
              <% end %>
            </div>
          </div>
        </:col>
        <:col :let={{_id, account}} label="Nome">{account.name}</:col>
        <:col :let={{_id, account}} label="Banco">{account.bank}</:col>
        <:col :let={{_id, account}} label="Saldo">{format_currency(account.balance)}</:col>
        <:col :let={{_id, account}} label="Importa?">
          <div class="flex justify-center">
            <%= if account.accepts_import do %>
              <.icon name="hero-check-circle" class="size-5 text-success" title="Aceita importação" />
            <% else %>
              <.icon name="hero-x-circle" class="size-5 text-base-300" title="Manual/Automático apenas" />
            <% end %>
          </div>
        </:col>
        <:action :let={{_id, account}}>
          <div class="flex gap-2">
            <.link navigate={~p"/accounts/#{account}/edit"} class="btn btn-ghost btn-xs">Editar</.link>
            <button phx-click="confirm_delete" phx-value-id={account.id} class="btn btn-ghost btn-xs text-error">Excluir</button>
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
        <h2 class="text-2xl font-black mb-2">Excluir Conta?</h2>
        <p class="text-base-content/60 mb-10">Deseja realmente apagar esta conta? Esta ação removerá o registro permanentemente.</p>
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
     |> assign(:page_title, "Listando Contas")
     |> assign(:confirm_modal, nil)
     |> stream(:accounts, Accounts.list_accounts())}
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
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)
    {:noreply, socket |> assign(:confirm_modal, nil) |> stream_delete(:accounts, account)}
  end
end
