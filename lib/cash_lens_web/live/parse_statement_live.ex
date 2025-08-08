defmodule CashLensWeb.ParseStatementLive do
  use CashLensWeb, :live_view

  alias CashLens.Parsers

  @impl true
  def mount(_params, _session, socket) do
    statements = list_statement_files()
    parsers = Parsers.list_parsers()

    {:ok, assign(socket,
      statements: statements,
      parsers: parsers,
      show_parser_modal: false,
      selected_statement: nil,
      transactions: nil
    )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_parsers", %{"path" => path}, socket) do
    statement = Enum.find(socket.assigns.statements, &(&1.path == path))

    {:noreply, assign(socket,
      show_parser_modal: true,
      selected_statement: statement
    )}
  end

  @impl true
  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, show_parser_modal: false)}
  end

  @impl true
  def handle_event("parse_file", %{"parser" => parser_module}, socket) do
    statement = socket.assigns.selected_statement

    # Find the parser module
    parser = Enum.find(socket.assigns.parsers, &(&1.module == parser_module))
    parser_module = String.to_existing_atom(parser_module)

    # Read file with latin1 encoding
    transactions =
      statement.path
      |> File.stream!
      |> Stream.map(& :unicode.characters_to_binary(&1, :latin1))
      |> parser_module.parse

    # Parse the content

    {:noreply, assign(socket,
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
                    <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-zinc-900 sm:pl-6">Filename</th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">Size</th>
                    <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-zinc-900">Last Modified</th>
                    <th scope="col" class="relative py-3.5 pl-3 pr-4 sm:pr-6">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-200 bg-white">
                  <%= for statement <- @statements do %>
                    <tr>
                      <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-zinc-900 sm:pl-6"><%= statement.filename %></td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500"><%= format_size(statement.size) %></td>
                      <td class="whitespace-nowrap px-3 py-4 text-sm text-zinc-500"><%= format_date(statement.last_modified) %></td>
                      <td class="relative whitespace-nowrap py-4 pl-3 pr-4 text-right text-sm font-medium sm:pr-6">
                        <button
                          phx-click="show_parsers"
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
      <%= if @transactions do %>
    <.table id="transactions" rows={@transactions}>
    <:col :let={transaction} label="Date">{Calendar.strftime(transaction.datetime, "%Y-%m-%d %H:%M")}</:col>
    <:col :let={transaction} label="Account">{transaction.account && transaction.account.name || "-"}</:col>
    <:col :let={transaction} label="Value" class="text-right">{transaction.value}</:col>
    <:col :let={transaction} label="Reason">{transaction.reason || "-"}</:col>
    <:col :let={transaction} label="Category">{if transaction.category, do: transaction.category.name, else: "-"}</:col>
    <:col :let={transaction} label="Refundable">{if transaction.refundable, do: "Yes", else: "No"}</:col>

    <:action :let={transaction}>
      <%= if transaction.id do %>
        <div class="sr-only">
          <.link navigate={~p"/transactions/#{transaction}"}>Show</.link>
        </div>
        <.link navigate={~p"/transactions/#{transaction}/edit"}>Edit</.link>
      <% else %>
        <span class="text-gray-400">Edit</span>
      <% end %>
    </:action>
    <:action :let={transaction}>
      <%= if transaction.id do %>
        <.link phx-click={show_modal("confirm-modal-#{transaction.id}")}>
          Delete
        </.link>
        <.confirm_modal id={"confirm-modal-#{transaction.id}"} on_confirm={~p"/transactions/#{transaction.id}"} method="delete">
          Are you sure you want to delete this transaction?
        </.confirm_modal>
      <% else %>
        <span class="text-gray-400">Delete</span>
      <% end %>
    </:action>
    </.table>      <% end %>

      <%= if @show_parser_modal do %>
        <div class="fixed inset-0 bg-gray-500 bg-opacity-75 flex items-center justify-center z-50">
          <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
            <div class="flex justify-between items-center mb-4">
              <h3 class="text-lg font-medium text-gray-900">Select Parser</h3>
              <button phx-click="close_modal" class="text-gray-400 hover:text-gray-500">
                <span class="sr-only">Close</span>
                <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>

            <p class="mb-4 text-sm text-gray-500">
              Select a parser for <%= @selected_statement && @selected_statement.filename %>
            </p>

            <div class="space-y-2">
              <%= for parser <- @parsers do %>
                <button
                  phx-click="parse_file"
                  phx-value-parser={parser.module}
                  class="w-full text-left px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
                >
                  <%= parser.name %>
                </button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 2)} KB"
  defp format_size(size), do: "#{Float.round(size / (1024 * 1024), 2)} MB"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end
end
