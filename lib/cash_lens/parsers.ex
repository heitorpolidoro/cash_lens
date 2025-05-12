defmodule CashLens.Parsers do
  @moduledoc """
  Module for handling different file parsers for transaction data.
  """
  import Number.Currency

  alias Timex
  alias CashLens.ReasonsToIgnore

  @doc """
  Returns a list of available parsers.
  """
  def available_parsers do
    [
      %{name: "Banco do Brasil", extension: :csv, slug: :bb_csv}
    ]
  end

  def available_parsers_slugs do
    available_parsers()
    |> Enum.map(fn parser -> parser.slug end)
  end

  def get_parser_by_slug(slug) do
    available_parsers()
    |> Enum.find(fn parser -> parser.slug == String.to_atom(slug) end)
  end

  def format_parser(parser) do
    "#{parser.name} (#{String.upcase(to_string(parser.extension))})"
  end

  @doc """
  Parses the file content using the specified parser.
  """
  def parse(content, :bb_csv) do
    reasons_to_ignore = ReasonsToIgnore.get_reasons_to_ignore_by_parser!(:bb_csv)
    |> IO.inspect()
    substrings_to_remove = []
#    substrings_to_remove = ["Compra com Cartão -"]

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
            # TODO REPLACE THE HARDCODED YEAR
            %{date_time: "#{date}/2025 #{time}", reason: String.replace(reason, date_time, "")}

          nil ->
            %{date_time: "#{row["Data"]} 00:00", reason: reason}
        end

      reason =
        Enum.reduce(substrings_to_remove, parsed_info.reason, fn substring, acc ->
          String.replace(acc, substring, "", global: true)
        end)
        |> String.trim()

      %{
        date_time: Timex.parse!(parsed_info.date_time, "{D}/{M}/{YYYY} {h24}:{m}"),
        reason: reason,
        amount: number_to_currency(row["Valor"], unit: "R$", separator: ",", delimiter: "."),
        identifier: row["Número do documento"],
        category: nil
      }
    end)
  end
end
