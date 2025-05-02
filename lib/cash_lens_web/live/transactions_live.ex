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
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-semibold text-gray-900">Transactions</h1>

      <div class="bg-white shadow sm:rounded-lg">
        <div class="px-4 py-5 sm:p-6">
          <h3 class="text-lg font-medium leading-6 text-gray-900">Upload Transactions</h3>
          <div class="mt-2 max-w-xl text-sm text-gray-500">
            <p>Upload a file containing your transactions.</p>
          </div>


          <div class="mt-5">
            <div class="mb-4">
              <label for="parser-select" class="block text-sm font-medium text-gray-700">Select Parser</label>
              <select id="parser-select" name="parser" phx-change="change-parser" class="mt-1 block w-full pl-3 pr-10 py-2 text-base border-gray-300 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm rounded-md">
                <%= for {label, value} <- @available_parsers do %>
                  <option value={value} selected={@parser_type == value}><%= label %></option>
                <% end %>
              </select>
            </div>

            <div class="mb-4">
              <label for="bank-select" class="block text-sm font-medium text-gray-700">Select Account <span class="text-red-500">*</span></label>
              <select id="bank-select" name="bank" phx-change="change-bank" class="mt-1 block w-full pl-3 pr-10 py-2 text-base border-gray-300 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm rounded-md">
                <option value="" selected={is_nil(@selected_bank)}>-- Select an Account --</option>
                <%= for bank_name <- @bank_names do %>
                  <option value={bank_name} selected={@selected_bank == bank_name}><%= bank_name %></option>
                <% end %>
              </select>
              <%= if is_nil(@selected_bank) do %>
                <p class="mt-1 text-sm text-red-500">Please select an account</p>
              <% end %>
            </div>

            <form id="upload-form" phx-submit="save" phx-change="validate" class="space-y-4">
              <.live_file_input upload={@uploads.transaction_file} />
              <div>
                <button type="submit" class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500" }>
                  Upload
                </button>
             </div>
            </form>
          </div>
        </div>
      </div>

      <div class="bg-white shadow sm:rounded-lg">
        <div class="px-4 py-5 sm:p-6">
          <h3 class="text-lg font-medium leading-6 text-gray-900">Your Transactions</h3>
          <div class="mt-2">
            <%= cond do %>
              <% @parsing_status == :parsing -> %>
                <div class="flex items-center justify-center py-8">
                  <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-indigo-600"></div>
                  <p class="ml-4 text-sm text-gray-500">Parsing your file... This may take a moment.</p>
                </div>
              <% @parsing_status == :error -> %>
                <div class="flex items-center justify-center py-8">
                  <div class="rounded-full h-12 w-12 flex items-center justify-center bg-red-100 text-red-600">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                  </div>
                  <p class="ml-4 text-sm text-red-500">An error occurred while parsing your file. Please check the file format and try again.</p>
                </div>
              <% Enum.empty?(@transactions) -> %>
                <p class="text-sm text-gray-500">No transactions yet. Upload a file to get started.</p>
              <% true -> %>
                <div class="overflow-x-auto">
                  <table class="min-w-full divide-y divide-gray-200">
                    <thead class="bg-gray-50">
                      <tr>
                        <%= for {key, _} <- Enum.at(@transactions, 0) |> Map.to_list() do %>
                          <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                            <%= key %>
                          </th>
                        <% end %>
                      </tr>
                    </thead>
                    <tbody class="bg-white divide-y divide-gray-200">
                      <%= for transaction <- @transactions do %>
                        <tr>
                          <%= for {_, value} <- transaction |> Map.to_list() do %>
                            <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                              <%= value %>
                            </td>
                          <% end %>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
