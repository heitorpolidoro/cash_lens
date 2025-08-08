defmodule CashLensWeb.ParseStatementLive do
  use CashLensWeb, :live_view


  @impl true
  def mount(_params, _session, socket) do
    statements = list_statement_files()
    {:ok, assign(socket, statements: statements)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
                        <a href="#" class="text-indigo-600 hover:text-indigo-900">Parse</a>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
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
