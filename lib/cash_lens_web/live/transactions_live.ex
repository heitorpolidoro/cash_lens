defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

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
        transactions: Transactions.list_transactions([desc: :id]),
        available_parsers: Enum.map(Parsers.available_parsers(), fn p -> {p.name, p.extension} end),
        selected_parser: nil,
        parsing_status: nil,
        accounts: Accounts.list_accounts(),
        selected_account: nil
      )
     |> allow_upload(:transaction_file,
        accept: ~w(.csv),
        max_entries: 1,
        max_file_size: 10_000_000) # 10MB
    }
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("change-account", %{"account" => account_id}, socket) do
    default_parser = Accounts.get_account!(account_id).parser && Accounts.get_account!(account_id).parser.extension
    {:noreply, assign(socket, selected_account: account_id, selected_parser: default_parser)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :transaction_file, ref)}
  end

  def handle_event("save", %{"account" => account, "parser" => parser}, socket) do
    if is_nil(account) do
      {:noreply,
       socket
       |> put_flash(:error, "Please select an account before uploading a file.")
      }
    else
      # Process the uploaded file
      consumed_entries =
        consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
          # Send the file path to the TransactionParser GenServer for async parsing
          TransactionParser.parse_file(path, account, String.to_atom(parser), self(), entry.client_name)

          # Return the entry name
          {:ok, entry.client_name}
        end)

      file_names = Enum.join(consumed_entries, ", ")

      {:noreply,
       socket
       |> put_flash(:info, "File uploaded successfully: #{file_names}. Parsing in progress...")
       |> assign(:parsing_status, :parsing)
       }
    end
  end

  def error_to_string(:too_large), do: "File is too large"
  def error_to_string(:too_many_files), do: "You have selected too many files"
  def error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  @doc """
  Handle the message from the TransactionParser GenServer when parsing is complete.
  """
  def handle_info({:transactions_parsed, client_name, account, parser_type}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "File parsing completed: #{client_name} using #{parser_type} for account #{account} ")
     |> assign(
        parsing_status: :completed,
        selected_account: nil,
        selected_parser: nil,
        transactions: Transactions.list_transactions([desc: :id])
      )
    }
  end

  # Handle the error message from the TransactionParser GenServer when parsing fails.
  def handle_info({:transactions_parse_error, _client_name, error_message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, error_message)
     |> assign(:parsing_status, :error)
     |> assign(:transactions, Transactions.list_transactions([desc: :id]))
    }
  end

  def render(assigns) do
    CashLensWeb.TransactionsLiveHTML.transactions(assigns)
  end
end
