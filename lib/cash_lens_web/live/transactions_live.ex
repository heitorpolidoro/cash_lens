defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

  alias Phoenix.LiveView.JS
  alias CashLens.Accounts.Account
  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Parsers
  alias CashLens.StringHelper

  @statement_default_path "statements"

  @impl true
  def mount(_params, _session, socket) do
    transactions = Transactions.list_transactions()
    parsers = CashLens.Parsers.list_parsers()
    accounts = CashLens.Accounts.list_accounts() |> Enum.map(&serialize_account/1)

    {:ok,
     assign(socket,
       page_title: "Transactions",
       transactions: transactions,
       accounts: accounts,
       parsers: parsers,
       step: :select_statement,
       selected_statement: nil,
       selected_parser: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Transactions
        <:actions>
          <.button phx-click={show_modal("import_statement_modal")}>Import Statement</.button>
        </:actions>
      </.header>

      <.import_statement_modal
        step={@step}
        selected_statement={@selected_statement}
        selected_parser={@selected_parser}
        accounts={@accounts}
        parsers={@parsers}
      />

      <div class="mt-8">
        <.table
          id="transactions"
          rows={@transactions}
          row_class={fn transaction -> if Decimal.negative?(transaction.amount), do: "bg-red-50", else: "bg-green-50" end}
        >
          <:col :let={transaction} label="Date">
            {Calendar.strftime(transaction.date, "%d/%m/%Y")}
            <%= if transaction.time do %>
              <br />{transaction.time |> Time.from_iso8601!() |> Calendar.strftime("%H:%M")}
            <% end %>
          </:col>
          <:col :let={transaction} label="Account">
            <div class="m-0 p-0 leading-tight whitespace-nowrap">
              {transaction.account.bank}<br />
              {transaction.account.name}
            </div>
          </:col>
          <:col :let={transaction} label="Reason">
            {transaction.reason}
          </:col>
          <:col :let={transaction} label="Type">
            {StringHelper.to_tittle(transaction.type)}
          </:col>
          <:col :let={transaction} label="Category">
            {transaction.category}
          </:col>
          <:col :let={transaction} label="Amount">
            <span class={if Decimal.negative?(transaction.amount), do: "text-red-600", else: "text-green-600"}>
              {Number.Currency.number_to_currency(Decimal.abs(transaction.amount),
                unit: "R$ ",
                delimiter: ".",
                separator: ","
              )}
            </span>
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  def import_statement_modal(assigns) do
    path = @statement_default_path

    statements =
      path
      |> File.ls!()
      |> Enum.map(fn filename ->
        %{name: filename, path: Path.join(path, filename), id: Base.encode64(filename)}
      end)

    assigns =
      assigns
      |> assign(statements: statements)

    ~H"""
    <.modal id="import_statement_modal">
      <:title>
        Import Statement
      </:title>
      <h2 class="font-semibold">{@step |> Atom.to_string() |> Recase.to_title()}</h2>
      <%= case @step do %>
        <% :select_statement -> %>
          <.table
            id="statements"
            rows={@statements}
            row_click={fn statement -> JS.push("statement_selected", value: %{filename: statement.path}) end}
            row_id={& &1.path}
          >
            <:col :let={statement} label="File Name">
              {statement.name}
            </:col>
          </.table>
        <% :select_parser -> %>
          <.table
            id="parsers"
            rows={@parsers}
            row_click={fn parser -> JS.push("parser_selected", value: %{parser: parser.slug}) end}
            row_id={& &1.slug}
          >
            <:col :let={parser} label="Parser">
              {parser.name}
            </:col>
          </.table>
        <% :select_account -> %>
          <.table
            id="accounts"
            rows={@accounts}
            row_click={
              fn account ->
                JS.push("account_selected", value: %{account: account.id})
                |> hide_modal("import_statement_modal")
              end
            }
            row_id={& &1.name}
          >
            <:col :let={account} label="Parser">
              {Account.full_name(account)}
            </:col>
          </.table>
      <% end %>
    </.modal>
    """
  end

  @impl true
  def handle_event("statement_selected", %{"filename" => filename}, socket) do
    {:noreply, assign(socket, selected_statement: filename, step: :select_parser)}
  end

  @impl true
  def handle_event("parser_selected", %{"parser" => parser}, socket) do
    {:noreply, assign(socket, selected_parser: parser, step: :select_account)}
  end

  @impl true
  def handle_event("account_selected", %{"account" => account_id}, socket) do
    account =
      socket.assigns.accounts
      |> Enum.find(fn account ->
        account.id == account_id
      end)

    %{selected_statement: selected_statement, selected_parser: selected_parser} = socket.assigns

    socket =
      case Parsers.parse_statement(selected_statement, selected_parser, account) do
        {:ok, transactions} ->
          Transactions.create_transactions(transactions)

          socket
          |> assign(transactions: Transactions.list_transactions())
          |> put_flash(:info, "Transactions imported successfully!")

        {:error, error} ->
          put_flash(socket, :error, error)
      end

    {:noreply,
     assign(socket,
       step: :select_statement,
       selected_statement: nil,
       selected_parser: nil
     )}
  end

  defp serialize_account(account) do
    Map.put(account, :id, BSON.ObjectId.encode!(account._id))
  end
end
