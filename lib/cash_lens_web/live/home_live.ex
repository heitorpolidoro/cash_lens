defmodule CashLensWeb.HomeLive do
  use CashLensWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Home")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Bem-vindo ao CashLens
        <:subtitle>Sistema de análise financeira</:subtitle>
      </.header>

      <div class="space-y-12 divide-y">
        <div>
          <.simple_form for={%{}} as={:test} phx-submit="test_connections">
            <.button phx-disable-with="Testando..." class="w-full">
              Testar Conexões (MongoDB + Redis)
            </.button>
          </.simple_form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("test_connections", _params, socket) do
    mongo_status = test_mongo()
    redis_status = test_redis()

    message = "MongoDB: #{mongo_status}, Redis: #{redis_status}"

    {:noreply, put_flash(socket, :info, message)}
  end

  defp test_mongo do
    try do
      Mongo.find_one(:mongo, "test", %{})
      "✅ Conectado"
    rescue
      _ -> "❌ Erro"
    end
  end

  defp test_redis do
    try do
      Redix.command(:redix, ["PING"])
      "✅ Conectado"
    rescue
      _ -> "❌ Erro"
    end
  end
end
