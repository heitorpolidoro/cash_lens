defmodule CashLensWeb.ParsersLive do
  use CashLensWeb, :live_view
  use CashLensWeb.LiveHelpers

  require Logger

  alias CashLens.Parsers

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


  def handle_info({:transactions_parsed, transactions}, socket) do
    {:noreply,
     socket
     |> assign(transactions: transactions)}
  end

  def render(assigns) do
    CashLensWeb.ParsersLiveHTML.parsers(assigns)
  end
end
