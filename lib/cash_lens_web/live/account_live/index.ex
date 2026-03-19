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

      <div class="overflow-x-auto bg-base-100 rounded-2xl border border-base-300 shadow-sm">
        <table class="table table-zebra w-full text-xs">
          <thead class="bg-base-200/50">
            <tr>
              <th class="w-16 text-center">Ícone</th>
              <th>Nome</th>
              <th>Banco</th>
              <th>Extrator</th>
              <th class="text-center">Importa?</th>
              <th class="w-16"></th>
            </tr>
          </thead>
          <tbody id="accounts" phx-update="stream">
            <tr :for={{id, account} <- @streams.accounts} id={id} class="hover group border-b border-base-200 cursor-pointer" phx-click={JS.navigate(~p"/transactions?account_id=#{account.id}&return_to=accounts")}>
              <td class="text-center py-4">
                <div class="avatar mx-auto">
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
              </td>
              <td class="font-bold">{account.name}</td>
              <td class="opacity-70">{account.bank}</td>
              <td class="opacity-70">
                {translate_parser_type(account.parser_type)}
              </td>
              <td class="text-center">
                <%= if account.accepts_import do %>
                  <.icon name="hero-check-circle" class="size-5 text-success mx-auto" />
                <% else %>
                  <.icon name="hero-x-circle" class="size-5 text-base-300 mx-auto" />
                <% end %>
              </td>
        <td class="text-right">
          <div class="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
            <.link navigate={~p"/accounts/#{account}/edit"} class="btn btn-ghost btn-xs px-1" phx-click-stop>
              <.icon name="hero-pencil" class="size-3" />
            </.link>
            <button phx-click="confirm_delete" phx-value-id={account.id} phx-click-stop class="btn btn-ghost btn-xs text-error px-1">
              <.icon name="hero-trash" class="size-3" />
            </button>
          </div>
        </td>
            </tr>
          </tbody>
        </table>
      </div>
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
