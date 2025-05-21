defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view
  use CashLensWeb.LiveHelpers

  alias CashLens.Parsers
  alias CashLens.TransactionParser
  alias CashLens.Accounts
  alias CashLens.Transactions

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       current_user: session["current_user"],
       uploaded_files: [],
       current_path: "/transactions",
       transactions: Transactions.list_transactions(desc: :id),
       available_parsers: Parsers.available_parsers_options(),
       selected_parser: nil,
       parsing_status: nil,
       accounts: Accounts.list_accounts(),
       selected_account: nil
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

  def handle_event("change-account", %{"account" => ""}, socket) do
    {:noreply, assign(socket, selected_account: nil, selected_parser: nil)}
  end
  def handle_event("change-account", %{"account" => account_id}, socket) do
    account = Accounts.get_account!(account_id)
    default_parser = account.parser
    {:noreply, assign(socket, selected_account: account_id, selected_parser: default_parser) |> IO.inspect()}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :transaction_file, ref)}
  end

  def error_to_string(:too_large), do: "File is too large"
  def error_to_string(:too_many_files), do: "You have selected too many files"
  def error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  def handle_info({:transactions_parsed, transactions}, socket) do
    {:noreply,
     socket
     |> assign(transactions: transactions, parsing_status: :completed)}
  end


  def render(assigns) do
    CashLensWeb.TransactionsLiveHTML.transactions(assigns)
  end
end
