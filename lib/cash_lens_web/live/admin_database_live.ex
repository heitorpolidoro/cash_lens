defmodule CashLensWeb.AdminDatabaseLive do
  use CashLensWeb, :live_view
  alias CashLens.Repo

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Administração do Banco de Dados
        <:subtitle>Visualização e filtragem direta de tabelas.</:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
        <!-- Barra Lateral: Lista de Tabelas -->
        <div class="lg:col-span-1 space-y-4">
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-4">
              <h2 class="card-title text-xs uppercase opacity-50 font-black mb-2">Tabelas</h2>
              <div class="flex flex-col gap-1">
                <%= for table <- @tables do %>
                  <.link
                    patch={~p"/admin/db/#{table}"}
                    class={[
                      "btn btn-ghost btn-sm justify-start normal-case",
                      @active_table == table && "btn-active bg-primary/10 text-primary"
                    ]}
                  >
                    <.icon name="hero-table-cells" class="size-4 mr-2" />
                    {table}
                  </.link>
                <% end %>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Área Principal: Dados da Tabela -->
        <div class="lg:col-span-3">
          <%= if @active_table do %>
            <div class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden">
              <div class="card-body p-0">
                <div class="p-6 border-b border-base-200 flex justify-between items-center bg-base-200/20">
                  <h2 class="text-xl font-black uppercase tracking-tighter text-primary">
                    Tabela: {@active_table}
                  </h2>
                  <span class="badge badge-outline opacity-50">{length(@rows)} registros</span>
                </div>

                <div class="overflow-x-auto">
                  <form id={"filter-form-#{@active_table}"} phx-change="filter" class="m-0 p-0">
                    <table class="table table-zebra w-full text-[10px]">
                      <thead class="bg-base-200/50 text-[9px] uppercase border-b border-base-300">
                        <tr>
                          <%= for col <- @columns do %>
                            <th class="p-2 border-r border-base-300 last:border-0 min-w-[150px]">
                              <div class="flex flex-col gap-1">
                                <span class="font-black text-base-content/70">{col}</span>
                                <input
                                  type="text"
                                  name={"filters[#{col}]"}
                                  value={@filters[col]}
                                  placeholder="Filtrar..."
                                  phx-debounce="300"
                                  class="input input-bordered input-xs h-6 w-full font-normal"
                                />
                              </div>
                            </th>
                          <% end %>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- @rows do %>
                          <tr class="hover group border-b border-base-200">
                            <%= for col <- @columns do %>
                              <td class="p-2 border-r border-base-200 last:border-0 truncate max-w-xs">
                                {format_val(Map.get(row, col))}
                              </td>
                            <% end %>
                          </tr>
                        <% end %>
                        <%= if Enum.empty?(@rows) do %>
                          <tr>
                            <td
                              colspan={length(@columns)}
                              class="text-center py-20 opacity-30 italic text-sm"
                            >
                              Nenhum registro encontrado para os filtros aplicados.
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </form>
                </div>
              </div>
            </div>
          <% else %>
            <div class="flex flex-col items-center justify-center py-32 opacity-20">
              <.icon name="hero-circle-stack" class="size-24 mb-4" />
              <p class="font-black uppercase tracking-widest">Selecione uma tabela ao lado</p>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    tables = list_db_tables()
    {:ok, assign(socket, tables: tables, active_table: nil, columns: [], rows: [], filters: %{})}
  end

  @impl true
  def handle_params(%{"table" => table}, _uri, socket) do
    columns = list_table_columns(table)
    # Initialize empty filters for new columns
    filters = Map.new(columns, &{&1, ""})

    {:noreply,
     socket
     |> assign(active_table: table, columns: columns, filters: filters)
     |> fetch_rows()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply, socket |> assign(filters: filter_params) |> fetch_rows()}
  end

  # --- Database Logic ---

  defp list_db_tables do
    query =
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"

    case Repo.query(query) do
      {:ok, %{rows: rows}} -> List.flatten(rows)
      _ -> []
    end
  end

  defp list_table_columns(table) do
    query =
      "SELECT column_name FROM information_schema.columns WHERE table_name = $1 AND table_schema = 'public' ORDER BY ordinal_position"

    case Repo.query(query, [table]) do
      {:ok, %{rows: rows}} -> List.flatten(rows)
      _ -> []
    end
  end

  defp fetch_rows(socket) do
    table = socket.assigns.active_table
    columns = socket.assigns.columns
    filters = socket.assigns.filters

    # Construct dynamic query
    base_query = "SELECT * FROM #{table}"

    # Build WHERE clauses using positional parameters for safety
    {where_clauses, params} =
      filters
      |> Enum.filter(fn {_, v} -> v != "" and v != nil end)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {{col, val}, idx}, {clauses, acc_params} ->
        # Use $1, $2, etc for security and text casting for matching
        {clauses ++ ["#{col}::text ILIKE $#{idx}"], acc_params ++ ["%#{val}%"]}
      end)

    final_query =
      if Enum.empty?(where_clauses) do
        base_query
      else
        base_query <> " WHERE " <> Enum.join(where_clauses, " AND ")
      end

    final_query = final_query <> " ORDER BY inserted_at DESC LIMIT 100"

    case Repo.query(final_query, params) do
      {:ok, %{rows: rows}} ->
        mapped_rows =
          Enum.map(rows, fn row ->
            Enum.zip(columns, row) |> Map.new()
          end)

        assign(socket, rows: mapped_rows)

      {:error, error} ->
        IO.inspect(error, label: "DB ADMIN ERROR")
        assign(socket, rows: [])
    end
  end

  defp format_val(nil), do: "NULL"

  defp format_val(val) when is_binary(val) do
    if String.valid?(val) do
      val
    else
      # Likely a UUID or raw binary, convert to Hex
      "0x" <> Base.encode16(val)
    end
  end

  defp format_val(val), do: inspect(val)
end
