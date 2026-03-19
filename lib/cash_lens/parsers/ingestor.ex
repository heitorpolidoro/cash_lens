defmodule CashLens.Parsers.Ingestor do
  @moduledoc """
  Main entry point for statement ingestion. Detects format and dispatches to correct parser.
  """
  alias CashLens.Parsers.CSVParser
  alias CashLens.Parsers.PDFParser

  @doc """
  Parses the content based on the provided parser_type.
  """
  def parse(content, parser_type) do
    case parser_type do
      "bb_csv" ->
        IO.puts("Using BB CSV Parser")
        CSVParser.parse(content, :bb)

      "sem_parar_pdf" ->
        IO.puts("Using Sem Parar PDF Parser")
        PDFParser.parse(content, :sem_parar)

      _ ->
        {:error, "Extrator não configurado ou não suportado para esta conta."}
    end
  end
end
