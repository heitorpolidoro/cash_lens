defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

  alias Phoenix.LiveView.JS
  alias CashLens.Accounts.Account
  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Parsers
  alias CashLens.StringHelper
  alias CashLens.Category

  @statement_default_path "statements"

  @impl true
  def mount(_params, _session, socket) do
    transactions = Transactions.list_transactions()
    parsers = CashLens.Parsers.list_parsers()
    accounts = CashLens.Accounts.list_accounts() |> Enum.map(&serialize_account/1)
    categories = Category.list_categories()

    {:ok,
     assign(socket,
       page_title: "Transactions",
       transactions: transactions,
        accounts: accounts,
        parsers: parsers,
       categories: categories,
        step: :select_statement,
        selected_statement: nil,
       selected_parser: nil,
       editing_new_category_for: nil,
       cat_query_by_id: %{},
       cat_suggestions_by_id: %{},
       cat_open_for: nil
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
            <div class="flex flex-col gap-1 relative">
              <form phx-change="category_type" class="flex items-center gap-2">
                <input type="hidden" name="transaction_id" value={BSON.ObjectId.encode!(transaction._id)} />
                <input
                  type="text"
                  class="input"
                  name="q"
                  value={Map.get(@cat_query_by_id, BSON.ObjectId.encode!(transaction._id), transaction.category || "")}
                  placeholder="Search or add category"
                  phx-debounce="300"
                />
              </form>

              <%= if @cat_open_for == BSON.ObjectId.encode!(transaction._id) do %>
                <% q = Map.get(@cat_query_by_id, BSON.ObjectId.encode!(transaction._id), "") %>
                <% suggestions = Map.get(@cat_suggestions_by_id, BSON.ObjectId.encode!(transaction._id), []) %>
                <div class="absolute z-10 mt-10 w-64 max-h-56 overflow-auto bg-white border rounded shadow">
                  <%= for cat <- suggestions do %>
                    <button type="button"
                            class="block w-full text-left px-3 py-2 hover:bg-gray-100"
                            phx-click="choose_category"
                            phx-value-id={BSON.ObjectId.encode!(transaction._id)}
                            phx-value-category={cat}>
                      {cat}
                    </button>
                  <% end %>
                  <button type="button"
                          class="block w-full text-left px-3 py-2 hover:bg-gray-100 border-t"
                          phx-click="add_new_category"
                          phx-value-id={BSON.ObjectId.encode!(transaction._id)}
                          phx-value-q={q}>
                    + add {q}
                  </button>
                </div>
              <% end %>
            </div>
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
          |> assign(transactions: Transactions.list_transactions(), categories: Category.list_categories())
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

  @impl true
  def handle_event("category_type", %{"transaction_id" => id, "q" => q}, socket) do
    q = q |> to_string() |> String.trim()
    suggestions = if q == "", do: [], else: Category.search_categories(q, 10)

    {:noreply,
     socket
     |> assign(
       cat_query_by_id: Map.put(socket.assigns.cat_query_by_id, id, q),
       cat_suggestions_by_id: Map.put(socket.assigns.cat_suggestions_by_id, id, suggestions),
       cat_open_for: id
     )}
  end

  @impl true
  def handle_event("choose_category", %{"id" => id, "category" => category}, socket) do
    case Transactions.update_transaction(id, %{category: category}) do
      {:ok, _trx} ->
        {:noreply,
         socket
         |> assign(
           transactions: Transactions.list_transactions(),
           categories: Category.list_categories(),
           cat_query_by_id: Map.delete(socket.assigns.cat_query_by_id, id),
           cat_suggestions_by_id: Map.delete(socket.assigns.cat_suggestions_by_id, id),
           cat_open_for: nil,
           editing_new_category_for: nil
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update category")}
    end
  end

  @impl true
  def handle_event("add_new_category", %{"id" => id, "q" => category}, socket) do
    category = category |> to_string() |> String.trim()

    if category == "" do
      {:noreply, put_flash(socket, :error, "Category can't be blank")}
    else
      case Transactions.update_transaction(id, %{category: category}) do
        {:ok, _trx} ->
          {:noreply,
           socket
           |> assign(
             transactions: Transactions.list_transactions(),
             categories: Category.list_categories(),
             cat_query_by_id: Map.delete(socket.assigns.cat_query_by_id, id),
             cat_suggestions_by_id: Map.delete(socket.assigns.cat_suggestions_by_id, id),
             cat_open_for: nil,
             editing_new_category_for: nil
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save new category")}
      end
    end
  end

  defp serialize_account(account) do
    Map.put(account, :id, BSON.ObjectId.encode!(account._id))
  end
end
