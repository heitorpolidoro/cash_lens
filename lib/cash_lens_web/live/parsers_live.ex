defmodule CashLensWeb.ParsersLive do
  use CashLensWeb, :live_view
  on_mount CashLensWeb.BaseLive

  require Logger

  alias CashLens.Parsers
  alias CashLens.TransactionParser

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/parsers",
       parsers: Parsers.available_parsers(),
       selected_parser: Parsers.get_parser_by_slug(:bb_csv),
#       selected_parser: nil,
       is_testing: false,
       transactions: [],
     )}
  end

  def create(conn, params) do
    IO.inspect(conn)
    IO.inspect(params)
    conn
  end

  def handle_event("select-parser", %{"slug" => slug} = params, socket) do
    is_testing = Map.get(params, "test", false) == "true"

    {:noreply, assign(socket, selected_parser: Parsers.get_parser_by_slug(slug), is_testing: is_testing)}
  end

  def handle_event("handle-file-upload", %{"filename" => filename, "content" => content, "type" => type, "size" => size}, socket) do
    # Print file information to terminal
    IO.puts("Filename: #{filename}")
    IO.puts("Type: #{type}")
    IO.puts("Content sample: #{String.slice(content, 0, 100)}...")

    # Get the selected parser
    parser_slug = socket.assigns.selected_parser.slug

    # For now, just return the socket without changes
    {:noreply, socket}
  end


  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
