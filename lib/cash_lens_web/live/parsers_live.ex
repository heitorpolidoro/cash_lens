defmodule CashLensWeb.ParsersLive do
  use CashLensWeb, :live_view
  require Logger

  alias CashLens.Parsers
  alias CashLens.TransactionParser

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_user: session["current_user"],
       current_path: "/parsers",
       parsers: Parsers.available_parsers(),
       selected_parser: nil,
       show_form: false,
       transactions: []
     )
     |> allow_upload(:transaction_file,
       accept: ~w(.csv),
       max_entries: 1,
       # 10MB
       max_file_size: 10_000_000
     )}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("test", %{"slug" => slug}, socket) do
    {:noreply, assign(socket, selected_parser: Parsers.get_parser_by_slug(slug))}
  end

  def handle_event("save", _params, socket) do
    file_name =
      consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
        # Send the file path to the TransactionParser GenServer for async parsing
        TransactionParser.parse_file(path, socket.assigns.selected_parser.slug, self())

        {:ok, entry.client_name}
      end)

    {:noreply, socket}
  end

  def handle_info({:flash, level, message}, socket) do
    {:noreply,
     socket
     |> put_flash(level, message)}
  end

  def handle_info({:transactions_parsed, transactions}, socket) do
    {:noreply,
     socket
     |> assign(transactions: transactions)}
  end

  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
