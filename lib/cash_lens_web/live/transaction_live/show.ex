defmodule CashLensWeb.TransactionLive.Show do
  use CashLensWeb, :live_view

  alias CashLens.Transactions

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Transaction {@transaction.id}
        <:subtitle>This is a transaction record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/transactions"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/transactions/#{@transaction}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit transaction
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Date">{@transaction.date}</:item>
        <:item title="Description">{@transaction.description}</:item>
        <:item title="Amount">{@transaction.amount}</:item>
        <:item title="Category">{@transaction.category}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Transaction")
     |> assign(:transaction, Transactions.get_transaction!(id))}
  end
end
