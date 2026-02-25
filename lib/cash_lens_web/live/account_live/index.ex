defmodule CashLensWeb.AccountLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
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
      <:col :let={{_id, account}} label="Nome">{account.name}</:col>
      <:col :let={{_id, account}} label="Banco">{account.bank}</:col>
      <:col :let={{_id, account}} label="Saldo">{format_currency(account.balance)}</:col>
      <:col :let={{_id, account}} label="Cor">{account.color}</:col>
      <:col :let={{_id, account}} label="Ícone">{account.icon}</:col>
      <:action :let={{_id, account}}>
        <div class="sr-only">
          <.link navigate={~p"/accounts/#{account}"}>Exibir</.link>
        </div>
        <.link navigate={~p"/accounts/#{account}/edit"}>Editar</.link>
      </:action>
      <:action :let={{id, account}}>
        <.link
          phx-click={JS.push("delete", value: %{id: account.id}) |> hide("##{id}")}
          data-confirm="Tem certeza que deseja excluir esta conta?"
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
     |> assign(:page_title, "Listando Contas")
     |> stream(:accounts, list_accounts())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)

    {:noreply, stream_delete(socket, :accounts, account)}
  end

  defp list_accounts() do
    Accounts.list_accounts()
  end
end
