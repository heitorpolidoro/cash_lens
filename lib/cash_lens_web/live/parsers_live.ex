defmodule CashLensWeb.ParsersLive do
  use CashLensWeb, :live_view
  on_mount CashLensWeb.BaseLive

  require Logger

  alias CashLens.Parsers

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/parsers",
       parsers: Parsers.available_parsers(),
       selected_parser: Parsers.get_parser_by_slug(:bb_csv),
       is_testing: false,
#       selected_parser: nil,
#       is_testing: false,
       transactions: [],
       upload_file: nil,
       action: nil,
     )
     |> allow_upload(:transaction_file,
       accept: ~w(.csv),
       max_entries: 1,
       # 10MB
       max_file_size: 10_000_000
     )}
  end


  def handle_event("select-parser", %{"slug" => slug} = params, socket) do
    is_testing = Map.get(params, "test", false) == "true"

    {:noreply, assign(socket, selected_parser: Parsers.get_parser_by_slug(slug), is_testing: is_testing)}
  end

  def handle_event("parse", _params, socket) do
    consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
      # Send the file path to the TransactionParser GenServer for async parsing
      TransactionParser.parse_file(path, socket.assigns.selected_parser.slug, self())


      {:ok, entry.client_name}
    end) |> IO.inspect()

    {:noreply, socket}
  end

  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
