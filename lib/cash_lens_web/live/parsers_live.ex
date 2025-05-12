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
       testing_parser: nil,
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
    {:noreply, assign(socket, testing_parser: Parsers.get_parser_by_slug(slug))}
  end

  def handle_event("save", _params, socket) do
    file_name =
      consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
        # Send the file path to the TransactionParser GenServer for async parsing
        TransactionParser.parse_file(path, socket.assigns.testing_parser.slug, self())

        {:ok, entry.client_name}
      end)

    {:noreply,
     socket
     |> put_flash(:info, "File uploaded successfully: #{file_name}. Parsing in progress...")}
  end

  def handle_info({:transactions_parsed, transactions}, socket) do
    IO.inspect(socket.assigns.uploads.transaction_file.entries)
    {:noreply,
     socket
     #      |> put_flash(:info, "File parsing completed: #{client_name} using #{parser_type} for account #{account} ")
     |> assign(transactions: transactions)}
  end

  def handle_event("ignore-reason", %{"reason" => reason}, socket) do
    parser = socket.assigns.testing_parser

    {level, message} =
      case CashLens.ReasonsToIgnore.create_reason_to_ignore(%{
             reason: reason,
             parser: parser.slug
           }) do
        {:ok, reason} ->
          {:info, "Ignoring reason \"#{reason.reason}\" for #{Parsers.format_parser(parser)}"}

        other ->
          other
      end

    Logger.log(level, message)

    {:noreply,
     socket
     |> put_flash(level, message)}
  end

  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
