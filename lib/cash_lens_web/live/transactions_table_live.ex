defmodule CashLensWeb.TransactionsTableLive do
  use CashLensWeb, :live_component

  alias CashLens.Transactions
  alias CashLens.Helper
  @impl true
  def mount(socket) do
    transactions = Transactions.list_transactions()

    {:ok,
     assign(socket,
       transactions: transactions,
       selected_date: nil
     )}
  end

  @impl true
  def handle_event("date_selected", %{"date" => date_str}, socket) do
    # Parse the string into a DateTime if needed
    {:ok, _date} = Date.from_iso8601(date_str)

    {
      :noreply,
      socket
      |> assign(selected_date: date_str)
      |> filter_transactions()
    }
  end

  defp filter_transactions(socket) do
    filter = Map.take(socket.assigns, [:selected_date])

    transactions =
      Transactions.find_transactions(filter, preload: true)

    assign(socket, transactions: transactions)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <form phx-change="date_selected" phx-target={@myself}>
        <.input type="date" id="date" name="date" value={@selected_date} />
      </form>

      <.table id="transactions" rows={@transactions} row_click={&JS.navigate(~p"/transactions/#{&1}")}>
        <:col :let={transaction} label="Date">
          {Calendar.strftime(transaction.datetime, "%Y-%m-%d %H:%M")}
        </:col>
        <:col :let={transaction} label="Account">{transaction.account.name}</:col>
        <:col :let={transaction} label="Amount">
          <div class="text-right">
            <span class={
              cond do
                Decimal.gt?(transaction.amount, 0) -> "text-blue-600"
                Decimal.lt?(transaction.amount, 0) -> "text-red-600"
                true -> ""
              end
            }>
              {Helper.format_currency(transaction.amount)}
            </span>
          </div>
        </:col>
        <:col :let={transaction} label="Reason">{transaction.reason || "-"}</:col>
        <:col :let={transaction} label="Category">
          {if transaction.category, do: transaction.category.name, else: "-"}
        </:col>

        <:action :let={transaction}>
          <div class="sr-only">
            <.link navigate={~p"/transactions/#{transaction}"}>Show</.link>
          </div>
          <.link navigate={~p"/transactions/#{transaction}/edit"}>Edit</.link>
        </:action>
        <:action :let={transaction}>
          <.link phx-click={show_modal("confirm-modal-#{transaction.id}")}>
            Delete
          </.link>
          <.confirm_modal
            id={"confirm-modal-#{transaction.id}"}
            on_confirm={~p"/transactions/#{transaction.id}"}
            method="delete"
          >
            Are you sure you want to delete this transaction?
          </.confirm_modal>
        </:action>
      </.table>
    </div>
    """
  end
end
