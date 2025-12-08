defmodule CashLensWeb.DashboardLive do
  use CashLensWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard", data: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold mb-4">Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <div class="bg-gray-50 p-4 rounded-lg">
          <h3 class="font-semibold mb-2">MongoDB</h3>
          <button phx-click="load_mongo_data" class="bg-blue-500 text-white px-3 py-1 rounded">
            Carregar Dados
          </button>
        </div>

        <div class="bg-gray-50 p-4 rounded-lg">
          <h3 class="font-semibold mb-2">Redis</h3>
          <button phx-click="test_redis_cache" class="bg-red-500 text-white px-3 py-1 rounded">
            Testar Cache
          </button>
        </div>
      </div>

      <div :if={@data != []} class="mt-4">
        <h3 class="font-semibold mb-2">Dados:</h3>
        <pre class="bg-gray-100 p-3 rounded text-sm"><%= inspect(@data, pretty: true) %></pre>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("load_mongo_data", _params, socket) do
    data = load_sample_data()
    {:noreply, assign(socket, data: data)}
  end

  @impl true
  def handle_event("test_redis_cache", _params, socket) do
    cache_result = test_cache()
    {:noreply, put_flash(socket, :info, "Cache: #{cache_result}")}
  end

  defp load_sample_data do
    try do
      Mongo.insert_one(:mongo, "transactions", %{
        amount: 100.50,
        description: "Teste",
        date: DateTime.utc_now()
      })

      Mongo.find(:mongo, "transactions", %{}) |> Enum.to_list()
    rescue
      e -> [error: Exception.message(e)]
    end
  end

  defp test_cache do
    try do
      Redix.command(:redix, ["SET", "test_key", "test_value"])
      {:ok, value} = Redix.command(:redix, ["GET", "test_key"])
      "✅ #{value}"
    rescue
      e -> "❌ #{Exception.message(e)}"
    end
  end
end
