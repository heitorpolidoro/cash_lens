defmodule CashLens.Parsers do
  @moduledoc """
  Module for handling different file parsers for transaction data.
  """

  @doc """
  Returns a list of available parsers.
  """

  alias Timex
  def available_parsers do
    [
      {"BB (CSV)", :bb_csv}
    ]
  end

  @doc """
  Parses the file content using the specified parser.
  """
  def parse(content, parser_type) do
    case parser_type do
      :bb_csv ->
        parse_bb_csv(content)
    end
  end

  defp parse_bb_csv(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.take(6)
    |> CSV.decode!(headers: true)
    |> Enum.to_list()
    |> Enum.map(fn row ->
      row =
        Enum.map(row, fn {key, value} ->
          {:unicode.characters_to_binary(key, :latin1, :utf8),
           :unicode.characters_to_binary(value, :latin1, :utf8)}
        end)
        |> Enum.into(%{})

      %{
        date: Timex.parse!(row["Data"], "{D}/{M}/{YYYY}"),
        reason: row["Histórico"],
        amount: row["Valor"],
        identifier: row["Número do documento"]
      }
    end)
  end
end
