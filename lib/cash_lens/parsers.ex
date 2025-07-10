defmodule CashLens.Parsers do
  @moduledoc """
  Module for handling different file parsers for transaction data.
  """
  import Number.Currency

  alias Timex
  alias CashLens.ReasonsToIgnore
  alias CashLens.Transactions.Transaction
  alias CashLens.Categories

  @doc """
  Returns a list of available parsers.
  """
  def available_parsers do
    [
      %{name: "Banco do Brasil", extension: :csv, slug: :bb_csv},
      %{name: "Banco do Brasil2", extension: :csv, slug: :bb_csv2}
    ]
  end

  def format_parser(parser) when is_atom(parser) or is_binary(parser) do
    format_parser(get_parser_by_slug(parser))
  end
  def format_parser(parser) do
    "#{parser.name} (#{String.upcase(to_string(parser.extension))})"
  end

  def available_parsers_options do
    Enum.map(available_parsers(), fn p -> {format_parser(p), p.slug} end)
  end

  def available_parsers_slugs do
    available_parsers()
    |> Enum.map(fn parser -> parser.slug end)
  end

  def get_parser_by_slug(slug) when is_atom(slug) do
    available_parsers()
    |> Enum.find(fn parser -> parser.slug == slug end)
  end

  def get_parser_by_slug(slug) do
    get_parser_by_slug(String.to_atom(slug))
  end

  @doc """
  Parses the file content using the specified parser.
  """
  def parse(content, :bb_csv) do
    reasons_to_ignore = ReasonsToIgnore.get_reasons_to_ignore_by_parser!(:bb_csv)
    substrings_to_remove = []

    content
    |> String.split("\n", trim: true)
    |> Enum.take(6) # TODO REMOVE
    |> CSV.decode!(headers: true)
    |> Enum.to_list()
    |> Enum.filter(fn row ->
      !Enum.member?(reasons_to_ignore, row["Histórico"])
    end)
    |> Enum.map(fn row  ->
      date_time_regex = ~r/(\d{2}\/\d{2}) (\d{2}:\d{2})/

      reason = row["Histórico"]
      if (reason == nil), do: raise "Reason cannot be nil"

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
#      Process.sleep(1000)

      %Transaction{
        date_time: Timex.parse!(parsed_info.date_time, "{D}/{M}/{YYYY} {h24}:{m}"),
        reason: reason,
        amount: number_to_currency(row["Valor"], unit: "R$", separator: ",", delimiter: "."),
        identifier: row["Número do documento"],
        category: nil
      }
    end)
  end
end
