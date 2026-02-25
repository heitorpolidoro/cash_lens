defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  alias CashLens.Parsers.CSVParser

  @doc """
  Detects the format of the file content and parses it.
  """
  def parse(content, filename) do
    case detect_format(content, filename) do
      :csv_bb ->
        IO.puts("Detected BB CSV")
        CSVParser.parse(content, :bb)

      :csv_nubank ->
        IO.puts("Detected Nubank CSV")
        CSVParser.parse(content, :nubank)

      :csv_generic ->
        IO.puts("Detected Generic CSV")
        CSVParser.parse(content, :generic)

      :ofx ->
        IO.puts("Detected OFX")
        # To be implemented with an OFX parser
        {:error, "OFX parser not yet implemented"}

      :unknown ->
        # Here we would call Ollama for AI detection
        IO.puts("Format unknown, could call Ollama here")
        {:error, "Formato de arquivo não reconhecido automaticamente."}
    end
  end

  defp detect_format(content, filename) do
    ext = Path.extname(filename) |> String.downcase()
    first_line = content |> String.split("\n") |> List.first() |> String.downcase()

    cond do
      ext == ".ofx" -> :ofx
      ext == ".csv" && String.contains?(first_line, "dependencia origem") -> :csv_bb
      ext == ".csv" && String.contains?(first_line, "data,valor,identificador") -> :csv_nubank
      ext == ".csv" -> :csv_generic
      true -> :unknown
    end
  end
end
