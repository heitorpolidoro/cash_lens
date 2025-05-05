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
    reasons_to_ignore = ["Saldo Anterior", "BB Rende Fácil - Rende Facil"]
    substrings_to_remove = ["Compra com Cartão -"]

    content
    |> String.split("\n", trim: true)
    |> Enum.take(6)
    |> CSV.decode!(headers: true)
    |> Enum.to_list()
    |> Enum.map(fn row ->
      Enum.map(row, fn {key, value} ->
        {:unicode.characters_to_binary(key, :latin1, :utf8),
         :unicode.characters_to_binary(value, :latin1, :utf8)}
      end)
      |> Enum.into(%{})
    end)
    |> Enum.filter(fn row ->
      !Enum.member?(reasons_to_ignore, row["Histórico"])
    end)
    |> Enum.map(fn row ->
      date_time_regex = ~r/(\d{2}\/\d{2}) (\d{2}:\d{2})/

      reason = row["Histórico"]

      parsed_info =
        case Regex.run(date_time_regex, reason) do
          [date_time, date, time] ->
            %{date: "#{date}/2025", time: time, reason: String.replace(reason, date_time, "")}

          nil ->
            %{date: row["Data"], time: "00:00", reason: reason}
        end

      reason =
        Enum.reduce(substrings_to_remove, parsed_info.reason, fn substring, acc ->
          String.replace(acc, substring, "", global: true)
        end)
        |> String.trim()

      %{
        date: Timex.parse!(parsed_info.date, "{D}/{M}/{YYYY}"),
        time: Timex.parse!(parsed_info.time, "{h24}:{m}"),
        reason: reason,
        amount: row["Valor"],
        identifier: row["Número do documento"]
      }
      |> IO.inspect()
    end)
  end
end
