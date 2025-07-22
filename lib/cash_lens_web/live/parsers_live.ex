defmodule CashLensWeb.ParsersLive do
  use CashLensWeb, :live_view
  import CashLensWeb.BaseLive
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  require Logger

  alias CashLens.Parsers
  alias CashLens.TransactionParser
  alias CashLens.Categories

  def mount(_params, session, socket) do
    {:ok,
      socket
      |> assign(
        current_path: "/parsers",
        parsers: Parsers.available_parsers(),
        selected_parser: Parsers.get_parser_by_slug(:bb_csv),
  #     selected_parser: nil,
        categories_options: [{"New Category", "new"}] ++ (Categories.list_categories(socket.assigns.current_user.id)|> Enum.map(fn x -> {Categories.to_str(x), x.id} end)),
        is_testing: true,
        transactions: nil,
        )}
  end

  def handle_event("select-parser", %{"slug" => slug} = params, socket) do
    is_testing = Map.get(params, "test", false) == "true"

    {:noreply, assign(socket, selected_parser: Parsers.get_parser_by_slug(slug), is_testing: is_testing)}
  end

  def handle_event("handle-file-upload", %{"filename" => filename, "content" => content} = _params, socket) do
    # Get the selected parser
    parser_slug = socket.assigns.selected_parser.slug
    try do
      {:noreply, assign_async(socket, :transactions, fn -> {:ok, %{transactions: Parsers.parse(content, parser_slug)}} end)}
    rescue
      error ->
          {_module, _function, _args, location} = List.first(__STACKTRACE__)
          message = Map.get(error, :message, "#{error.__struct__}:#{location[:file]}:#{location[:line]}")
          Logger.error("Error parsing file: #{message}")
          {:noreply, put_flash(socket, :error, message)}
    end
    # For now, just return the socket without changes
  end


  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
