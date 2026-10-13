defmodule CashLensWeb.AccountLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Account {@account.name}
      <:subtitle>Detalhes da sua conta bancária registrada no sistema.</:subtitle>
      <:actions>
        <.button navigate={~p"/accounts"}>
          <.icon name="hero-arrow-left" />
        </.button>
        <.button variant="primary" navigate={~p"/accounts/#{@account}/edit?return_to=show"}>
          <.icon name="hero-pencil-square" /> Editar conta
        </.button>
      </:actions>
    </.header>

    <.list>
      <:item title="Nome">{@account.name}</:item>
      <:item title="Banco">{@account.bank}</:item>
      <:item title="Saldo">{@account.balance}</:item>
      <:item title="Cor">{@account.color}</:item>
      <:item title="Ícone">{@account.icon}</:item>
    </.list>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Detalhes da Conta")
     |> assign_account(id)
     # Same reason as the statement screen: a transaction typed from an
     # account's own page belongs to that account.
     |> assign(:new_transaction_account_id, id)}
  end

  # Another user's account is indistinguishable from a missing one: back to the
  # list, never rendering its data.
  defp assign_account(socket, id) do
    assign(socket, :account, Accounts.get_account!(socket.assigns.current_user, id))
  rescue
    Ecto.NoResultsError ->
      socket
      |> put_flash(:error, "Conta não encontrada.")
      |> push_navigate(to: ~p"/accounts")
  end
end
