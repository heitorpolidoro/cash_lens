defmodule CashLens.TransactionParser do
  @moduledoc """
  GenServer for asynchronously parsing transaction files.
  """
  use GenServer

  alias CashLens.Parsers

  # Client API

  @doc """
  Starts the transaction parser server.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Parse a transaction file asynchronously.

  ## Parameters

  - `file_path`: Path to the file to be parsed
  - `parser_type`: Type of parser to use (:csv_standard, :csv_nimble, etc.)
  - `caller`: PID of the process that will receive the parsing result
  - `client_name`: Name of the client that uploaded the file

  ## Returns

  - `:ok`: The parsing process has been started
  """
  def parse_file(file_path, parser_type, caller, client_name) do
    IO.inspect({file_path, parser_type, caller, client_name})
    GenServer.cast(__MODULE__, {:parse_file, file_path, parser_type, caller, client_name})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:parse_file, file_path, parser_type, caller, file_name}, state) do
    # Read the file content immediately to avoid issues with temporary files being deleted
    try do
      # Read the file content
      content = File.read!(file_path)

      # Spawn a process to do the parsing with the content already in memory
      IO.puts "Starting parsing"
      Task.start(fn ->
        try do
          # Parse the content
          transactions = Parsers.parse(content, parser_type)
            |> Enum.map(fn entry -> entry end)

          # Send the result back to the caller
          IO.puts "Parsing complete for #{file_name}"
          send(caller, {:transactions_parsed, file_name})
        rescue
          error ->
            error_message = "Error parsing file #{file_name}: #{Exception.message(error)}"
            IO.puts "Parsing error: #{error_message}"
            send(caller, {:transactions_parse_error, file_name, error_message})
        end
      end)
    rescue
      error ->
        error_message = "Error parsing file #{file_name}: #{Exception.message(error)}"
        IO.puts "Parsing error: #{error_message}"
        # Send the error message back to the caller immediately
        send(caller, {:transactions_parse_error, file_name, error_message})
    end

    {:noreply, state}
  end
end
