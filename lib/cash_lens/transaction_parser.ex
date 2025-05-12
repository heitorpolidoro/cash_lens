defmodule CashLens.TransactionParser do
  @moduledoc """
  GenServer for asynchronously parsing transaction files.
  """
  use GenServer

  require Logger

  alias CashLens.Parsers

  # Client API

  @doc """
  Starts the transaction parser server.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def send_flash_message(caller, level, message) do
    Logger.info(message)
    send(caller, {:flash, level, message})
  end

  def send_flash_message(caller, level, message, stack_trace) do
    Logger.error(Exception.format(:error, message, stack_trace))

    send(caller, {:flash, level, message})
  end

  @doc """
  Parse a transaction file asynchronously.

  ## Parameters

  - `file_path`: Path to the file to be parsed
  - `parser_type`: Type of parser to use
  - `caller`: PID of the process that will receive the parsing result
  - `client_name`: Name of the client that uploaded the file

  ## Returns

  - `:ok`: The parsing process has been started
  """
  def parse_file(file_path, parser_slug, caller) do
    GenServer.cast(
      __MODULE__,
      {:parse_file, file_path, parser_slug, caller}
    )

    send_flash_message(
      caller,
      :info,
      "File uploaded successfully: #{Path.basename(file_path)}. Parsing in progress..."
    )
  end

  # Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:parse_file, file_path, parser_type, caller}, state) do
    # Read the file content immediately to avoid issues with temporary files being deleted
    try do
      # Read the file content
      content = File.read!(file_path)

      # Spawn a process to do the parsing with the content already in memory
      Task.start(fn ->
        try do
          # Parse the content
          transactions =
            Parsers.parse(content, parser_type)

          send_flash_message(caller, :info, "Parsing completed successfully.")
          send(caller, {:transactions_parsed, transactions})
        rescue
          error ->
            error_message = Exception.message(error)

            send_flash_message(caller, :error, error_message, stacktrace: __STACKTRACE__)
        end
      end)
    rescue
      error ->
        error_message = Exception.message(error)
        Logger.error(Exception.format(:error, "Parsing error: #{error_message}", __STACKTRACE__))
        # Send the error message back to the caller immediately
        send(caller, {:transactions_parse_error, error_message})
    end

    {:noreply, state}
  end
end
