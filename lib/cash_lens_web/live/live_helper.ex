defmodule CashLensWeb.LiveHelpers do
  alias CashLens.TransactionParser

  defmacro __using__(_) do
    quote do
      def handle_info({:flash, level, message}, socket) do
        {:noreply, put_flash(socket, level, message)}
      end

      def handle_info({:transactions_parse_error, error_message}, socket) do
        {:noreply, put_flash(socket, :error, error_message)}
      end

      def handle_event("parse", _params, socket) do
        consume_uploaded_entries(socket, :transaction_file, fn %{path: path}, entry ->
          # Send the file path to the TransactionParser GenServer for async parsing
          TransactionParser.parse_file(path, socket.assigns.selected_parser.slug, self())

          {:ok, entry.client_name}
        end)

        {:noreply, socket}
      end
    end
  end
end
