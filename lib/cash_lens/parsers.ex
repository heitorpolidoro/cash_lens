defmodule CashLens.Parsers do
  @moduledoc """
  Module for handling different file parsers for transaction data.
  """

  @doc """
  Returns a list of available parsers.
  """
  def available_parsers do
    [
      {"BB (CSV)", :bb_csv},
      {"CSV (NimbleCSV)", :csv_nimble}
    ]
  end

  @doc """
  Parses the file content using the specified parser.
  """
  def parse(content, parser_type) do
    case parser_type do
      :bb_csv ->
        parse_bb_csv(content)
      :csv_nimble ->
        parse_with_nimble_csv(content)
      _ ->
        # Default to standard CSV parser if parser type is not recognized
        parse_bb_csv(content)
    end
  end

  defp parse_bb_csv(content) do
    content
    |> String.split("\n", trim: true)
    |> CSV.decode!(headers: true)
    |> Enum.to_list()
  end

  defp parse_with_nimble_csv(content) do
    # Using NimbleCSV's RFC4180 parser
    content
    |> String.split("\n", trim: true)
    |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
    |> convert_to_maps()
  end

  # Convert list of lists to list of maps with headers
  defp convert_to_maps([headers | rows]) do
    header_keys = Enum.map(headers, &String.to_atom/1)

    Enum.map(rows, fn row ->
      Enum.zip(header_keys, row)
      |> Enum.into(%{})
    end)
  end
  defp convert_to_maps([]), do: []
end
