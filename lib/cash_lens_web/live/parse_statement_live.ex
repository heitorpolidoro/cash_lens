defmodule CashLensWeb.ParseStatementLive do
  use CashLensWeb, :live_view

  alias CashLens.Parsers
  alias CashLens.Accounts

  @impl true
  def mount(_params, _session, socket) do
    statements = list_statement_files()
    parsers = Parsers.list_parsers()
    accounts = Accounts.list_accounts()

    {:ok,
     assign(socket,
       statements: statements,
       parsers: parsers,
       accounts: accounts,
       show_parser_modal: false,
       show_account_modal: false,
       selected_statement: nil,
       selected_parser: nil,
       selected_account: nil,
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
    {:noreply, assign(socket, show_parser_modal: false, show_account_modal: false)}
  end

  @impl true
  def handle_event("select_parser", %{"parser" => parser_module}, socket) do
    # Find the parser module
    parser = Enum.find(socket.assigns.parsers, &(&1.module == parser_module))
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
  def handle_event("parse_file", params, socket) do
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
    <div class="max-w-4xl mx-auto py-8 px-4 sm:px-6 lg:px-8">
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
      <.transactions_table transactions={@transactions} />

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

  def transactions_table(assigns) do
    ~H"""
    <%= if @transactions do %>
      <div class="bg-white shadow rounded-lg p-6">
        <.table id="transactions" rows={@transactions}>
          <:col :let={transaction} label="Date">
            {Calendar.strftime(transaction.datetime, "%d/%m/%Y\u00A0%H:%M")}
          </:col>
          <:col :let={transaction} label="Account">
            {(transaction.account && "#{transaction.account.bank_name}\n#{transaction.account.name}") || "-"}
          </:col>
          <:col :let={transaction} label="Value" class="text-right">
            <span class={
              cond do
                transaction.value > 0 -> "text-blue-600"
                transaction.value < 0 -> "text-red-600"
                true -> ""
              end
            }>
              {format_currency(transaction.value)}
            </span>
          </:col>
          <:col :let={transaction} label="Reason" >{transaction.reason || "-"}</:col>
          <:col :let={transaction} label="Category" >
            {if transaction.category, do: transaction.category.name, else: "-"}
          </:col>
          <:col :let={transaction} label="Refundable" >
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
