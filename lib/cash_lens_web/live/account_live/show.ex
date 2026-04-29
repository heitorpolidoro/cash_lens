defmodule CashLensWeb.AccountLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Account {@account.name}
      <:subtitle>Details of your bank account registered in the system.</:subtitle>
      <:actions>
        <.button navigate={~p"/accounts"}>
          <.icon name="hero-arrow-left" />
        </.button>
        <.button variant="primary" navigate={~p"/accounts/#{@account}/edit?return_to=show"}>
          <.icon name="hero-pencil-square" /> Edit account
        </.button>
      </:actions>
    </.header>

    <.list>
      <:item title="Name">{@account.name}</:item>
      <:item title="Bank">{@account.bank}</:item>
      <:item title="Balance">{@account.balance}</:item>
      <:item title="Color">{@account.color}</:item>
      <:item title="Icon">{@account.icon}</:item>
    </.list>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Account")
     |> assign(:account, Accounts.get_account!(id))}
  end
end
