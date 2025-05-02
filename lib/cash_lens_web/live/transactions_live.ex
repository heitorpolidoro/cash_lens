defmodule CashLensWeb.TransactionsLive do
  use CashLensWeb, :live_view

  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(current_user: session["current_user"], uploaded_files: [], current_path: "/transactions", transactions: [])
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
    # Process the uploaded file
    consumed_entries =
      consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
        # Here you would parse the file and save the transactions
        # For now, we'll just return the filename
        transactions = File.read!(path)
          |> String.split("\n", trim: true)
          |> CSV.decode!(headers: true)
          |> Enum.map(
            fn entry ->
              entry |> IO.inspect
            end
          )
        {:ok, entry.client_name}
      end)

    {:noreply,
     socket
     |> put_flash(:info, "File uploaded successfully: #{Enum.join(consumed_entries, ", ")}")
     |> assign(:transactions, [1])
     }
  end

  def error_to_string(:too_large), do: "File is too large"
  def error_to_string(:too_many_files), do: "You have selected too many files"
  def error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

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
            <form id="upload-form" phx-submit="save" phx-change="validate"  class="space-y-4">
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
            <!-- This is where the transactions table would go -->
            <p class="text-sm text-gray-500">No transactions yet. Upload a file to get started.</p>
            <%= for transaction <- @transactions do %>
              <tr>
                <td><%= transaction %></td>
              </tr>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
