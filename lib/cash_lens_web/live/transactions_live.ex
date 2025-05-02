defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

  alias CashLens.Parsers
  alias CashLens.TransactionParser
  alias CashLens.Accounts

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
        current_user: session["current_user"],
        uploaded_files: [],
        current_path: "/transactions",
        transactions: [],
        available_parsers: Parsers.available_parsers(),
        parser_type: :csv_standard,
        parsing_status: nil,
        bank_names: Accounts.list_bank_names(),
        selected_bank: nil
      )
     |> allow_upload(:transaction_file,
        accept: ~w(.csv),
        max_entries: 1,
        max_file_size: 10_000_000) # 10MB
    }
  end

  def validate_uploads(socket, upload_name) do
    # This function validates the uploads and returns the socket
    # It's called by the "validate" event handler
    socket
    |> Map.put(:uploads, Map.update!(socket.uploads, upload_name, fn upload ->
      # Validate each entry in the upload
      entries = for entry <- upload.entries do
        # Here you can add custom validation logic if needed
        entry
      end
      %{upload | entries: entries}
    end))
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
#    {:noreply, validate_uploads(socket, :transaction_file)}
  end

  def handle_event("change-parser", %{"parser" => parser_type}, socket) do
    {:noreply, assign(socket, parser_type: String.to_atom(parser_type))}
  end

  def handle_event("change-bank", %{"bank" => bank_name}, socket) do
    {:noreply, assign(socket, selected_bank: bank_name)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :transaction_file, ref)}
  end

  def handle_event("trigger-upload", _params, socket) do
    # Add an acknowledgment ID to the event
    ack_id = "upload-ack-#{:rand.uniform(1000000)}"
    {:noreply, push_event(socket, "click-file-input", %{ack: "file-input-clicked-#{ack_id}"})}
  end

  # Handle the acknowledgment event from the client
  def handle_event("file-input-clicked-" <> _ack_id, _params, socket) do
    # The client successfully processed the click-file-input event
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    if is_nil(socket.assigns.selected_bank) do
      {:noreply,
       socket
       |> put_flash(:error, "Please select an account before uploading a file.")
      }
    else
      # Process the uploaded file
      consumed_entries =
        consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
          # Send the file path to the TransactionParser GenServer for async parsing
          TransactionParser.parse_file(path, socket.assigns.parser_type, self(), entry.client_name)

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
  def handle_info({:transactions_parsed, client_name}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "File parsing completed: #{client_name}")
     |> assign(:parsing_status, :completed)
    }
  end

  # Handle the error message from the TransactionParser GenServer when parsing fails.
  def handle_info({:transactions_parse_error, _client_name, error_message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, error_message)
     |> assign(:parsing_status, :error)
    }
  end

  def render(assigns) do
    CashLensWeb.TransactionsLiveHTML.transactions(assigns)
  end
end
