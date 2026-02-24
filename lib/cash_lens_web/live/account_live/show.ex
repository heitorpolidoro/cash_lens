defmodule CashLensWeb.AccountLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Conta {@account.name}
        <:subtitle>Detalhes da sua conta bancária registrados no sistema.</:subtitle>
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
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Exibir Conta")
     |> assign(:account, Accounts.get_account!(id))}
  end
end
