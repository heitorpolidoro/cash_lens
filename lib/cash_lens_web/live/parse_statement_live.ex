defmodule CashLensWeb.ParseStatementLive do
  use CashLensWeb, :live_view

  alias CashLens.Parsers
  alias CashLens.Accounts
  alias CashLens.Categories

  @impl true
  def mount(_params, _session, socket) do
    statements = list_statement_files()
    parsers = Parsers.list_parsers()
    accounts = Accounts.list_accounts()
    categories = Categories.list_categories()

    {:ok,
     assign(socket,
       statements: statements,
       parsers: parsers,
       accounts: accounts,
       categories: categories,
       show_parser_modal: false,
       show_account_modal: false,
       show_new_category_modal: false,
       selected_statement: nil,
       selected_parser: nil,
       selected_account: nil,
       new_category_name: nil,
       new_category_transaction_index: nil,
       transactions: nil
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_statement", %{"path" => path}, socket) do
    statement = Enum.find(socket.assigns.statements, &(&1.path == path))

    {:noreply,
     assign(socket,
       show_parser_modal: true,
       selected_statement: statement
     )}
  end

  @impl true
  def handle_event("close_modals", _, socket) do
    {:noreply, assign(socket,
      show_parser_modal: false,
      show_account_modal: false,
      show_new_category_modal: false
    )}
  end

  @impl true
  def handle_event("select_parser", %{"parser" => parser_module}, socket) do
    # Find the parser module
    _parser = Enum.find(socket.assigns.parsers, &(&1.module == parser_module))
    parser_module = String.to_existing_atom(parser_module)

    {:noreply,
     assign(socket,
       show_parser_modal: false,
       show_account_modal: true,
       selected_parser: parser_module
     )}
  end

  @impl true
  def handle_event("select_account", %{"account_id" => account_id} = _params, socket) do
    selected_account = Accounts.get_account!(String.to_integer(account_id))

    socket =
      socket
      |> assign(
        selected_account: selected_account,
        show_account_modal: false
      )

    handle_event("parse_file", nil, socket)
  end

  @impl true
  def handle_event("parse_file", _params, socket) do
    statement = socket.assigns.selected_statement
    parser_module = socket.assigns.selected_parser
    selected_account = socket.assigns.selected_account

    # Read file with latin1 encoding
    transactions =
      statement.path
      |> File.stream!()
      |> Stream.map(&:unicode.characters_to_binary(&1, :latin1))
      |> parser_module.parse
      |> Enum.map(fn transaction -> %{transaction | account: selected_account} end)

    # Parse the content

    {:noreply,
     assign(socket,
       show_parser_modal: false,
       transactions: transactions
     )}
  end

  @impl true
  def handle_event("select_category", %{"value" => "new", "index" => index}, socket) do
    # Show the new category modal
    {:noreply,
     assign(socket,
       show_new_category_modal: true,
       new_category_transaction_index: String.to_integer(index),
       new_category_name: ""
     )}
  end

  @impl true
  def handle_event("select_category", %{"value" => category_id, "index" => index}, socket) do
    # Update the transaction with the selected category
    index = String.to_integer(index)
    category = Enum.find(socket.assigns.categories, &(&1.id == String.to_integer(category_id)))

    updated_transactions =
      socket.assigns.transactions
      |> List.update_at(index, fn transaction ->
        %{transaction | category: category}
      end)

    {:noreply, assign(socket, transactions: updated_transactions)}
  end

  @impl true
  def handle_event("update_new_category_name", %{"value" => name}, socket) do
    {:noreply, assign(socket, new_category_name: name)}
  end

  @impl true
  def handle_event("create_category", %{"category_name" => name}, socket) do
    # Create a new category
    case Categories.create_category(%{name: name}) do
      {:ok, category} ->
        # Update the transaction with the new category
        index = socket.assigns.new_category_transaction_index

        updated_transactions =
          socket.assigns.transactions
          |> List.update_at(index, fn transaction ->
            %{transaction | category: category}
          end)

        # Update the categories list
        updated_categories = [category | socket.assigns.categories]

        {:noreply,
         assign(socket,
           transactions: updated_transactions,
           categories: updated_categories,
           show_new_category_modal: false
         )}

      {:error, _changeset} ->
        # Show an error message
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create category. Name may already be taken.")
         |> assign(show_new_category_modal: false)}
    end
  end

  defp list_statement_files do
    Path.wildcard("statements/*.{csv,ofx,qif}")
    |> Enum.map(fn path ->
      %{
        path: path,
        filename: Path.basename(path),
        size: File.stat!(path).size,
        last_modified: File.stat!(path).mtime |> NaiveDateTime.from_erl!()
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto py-8 px-4 sm:px-6 lg:px-8">
      <h1 class="text-2xl font-semibold text-zinc-900 mb-6">Parse Statement</h1>

      <div class="bg-white shadow rounded-lg p-6">
        <p class="mb-4 text-zinc-600">
          Select a statement file to import transactions.
        </p>

        <div class="mt-6">
          <%= if @statements == [] do %>
            <div class="text-center py-8 text-zinc-500">
              <p>No statement files found in the statements folder.</p>
            </div>
          <% else %>
            <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
              <table class="min-w-full divide-y divide-zinc-300">
                <thead class="bg-zinc-50">
                  <tr>
                    <th
                      scope="col"
                      class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-zinc-900 sm:pl-6"
                    >
                      Filename
                    </th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">
                      Size
                    </th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">
                      Last Modified
                    </th>
                    <th scope="col" class="relative py-3.5 pl-3 pr-4 sm:pr-6">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-200 bg-white">
                  <%= for statement <- @statements do %>
                    <tr>
                      <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-zinc-900 sm:pl-6">
                        {statement.filename}
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500">
                        {format_size(statement.size)}
                      </td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500">
                        {format_date(statement.last_modified)}
                      </td>
                      <td class="relative whitespace-nowrap py-4 pl-3 pr-4 text-right text-sm font-medium sm:pr-6">
                        <button
                          phx-click="select_statement"
                          phx-value-path={statement.path}
                          class="text-indigo-600 hover:text-indigo-900"
                        >
                          Parse
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
      <.transactions_table transactions={@transactions} categories={@categories} />

      <.parser_modal
        show_parser_modal={@show_parser_modal}
        selected_statement={@selected_statement}
        parsers={@parsers}
      />
      <.account_modal
        show_account_modal={@show_account_modal}
        selected_statement={@selected_statement}
        accounts={@accounts}
      />
      <.new_category_modal
        show_new_category_modal={@show_new_category_modal}
        new_category_name={@new_category_name}
      />
    </div>
    """
  end

  def parser_modal(assigns) do
    ~H"""
    <%= if @show_parser_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Select Parser</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <p class="mb-4 text-sm text-gray-500">
            Select a parser for {@selected_statement && @selected_statement.filename}
          </p>

          <div class="space-y-2">
            <%= for parser <- @parsers do %>
              <button
                phx-click="select_parser"
                phx-value-parser={parser.module}
                class="w-full text-left px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
              >
                {parser.name}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  def account_modal(assigns) do
    ~H"""
    <%= if @show_account_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Select Account</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <p class="mb-4 text-sm text-gray-500">
            Select a Account for {@selected_statement && @selected_statement.filename}
          </p>

          <div class="space-y-2">
            <%= for account <- @accounts do %>
              <button
                phx-click="select_account"
                phx-value-account_id={account.id}
                class="w-full text-left px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
              >
                {Accounts.to_str(account)}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  def new_category_modal(assigns) do
    ~H"""
    <%= if @show_new_category_modal do %>
      <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
        <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900">Create New Category</h3>
            <button phx-click="close_modals" class="text-gray-400 hover:text-gray-500">
              <span class="sr-only">Close</span>
              <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <form phx-submit="create_category">
            <div class="mb-4">
              <label for="category_name" class="block text-sm font-medium text-gray-700">Category Name</label>
              <input
                type="text"
                name="category_name"
                id="category_name"
                value={@new_category_name}
                phx-keyup="update_new_category_name"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                placeholder="Enter category name"
                required
              />
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex justify-center rounded-md border border-transparent bg-indigo-600 py-2 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2"
              >
                Create
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  def transactions_table(assigns) do
    ~H"""
    <%= if @transactions do %>
      <div class="bg-white shadow rounded-lg p-6">
        <.table id="transactions" rows={Enum.with_index(@transactions)}>
          <:col :let={{transaction, _index}} label="Date">
            {Calendar.strftime(transaction.datetime, "%d/%m/%Y %H:%M")}
          </:col>
          <:col :let={{transaction, _index}} label="Account">
            {(transaction.account && Accounts.to_str(transaction.account)) || "-"}
          </:col>
          <:col :let={{transaction, _index}} label="Value">
            <div class="text-right">
              <span class={
                cond do
                  transaction.value > 0 -> "text-blue-600"
                  transaction.value < 0 -> "text-red-600"
                  true -> ""
                end
              }>
                {format_currency(transaction.value)}
              </span>
            </div>
          </:col>
          <:col :let={{transaction, _index}} label="Reason" >{transaction.reason || "-"}</:col>
          <:col :let={{transaction, index}} label="Category" >
            <select
              phx-change="select_category"
              phx-value-index={index}
              class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
            >
              <option value="" disabled selected={is_nil(transaction.category)}>-- Select Category --</option>
              <%= for category <- @categories do %>
                <option value={category.id} selected={transaction.category && transaction.category.id == category.id}>
                  {category.name}
                </option>
              <% end %>
              <option value="new">+ Create New Category</option>
            </select>
          </:col>
          <:col :let={{transaction, _index}} label="Refundable" >
            {if transaction.refundable, do: "Yes", else: "No"}
          </:col>
        </.table>
      </div>
    <% end %>
    """
  end

  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 2)} KB"
  defp format_size(size), do: "#{Float.round(size / (1024 * 1024), 2)} MB"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_currency(value) do
    "R$\u00A0#{:erlang.float_to_binary(abs(value), decimals: 2)}"
  end
end
