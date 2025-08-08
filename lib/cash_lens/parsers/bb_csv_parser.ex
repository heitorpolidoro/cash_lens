defmodule CashLens.Parsers.BBCSVParser do
  @moduledoc """
  Parser for Banco do Brasil CSV statement files.
  """
  @name "BB CSV"

  alias CashLens.Transactions.Transaction
  alias Timex

  # Define a custom parser with comma as separator
  NimbleCSV.define(Parser, separator: ",", escape: "\"")

  def name, do: @name

  @doc """
  Parses a CSV file content and returns structured transaction data.

  The CSV is expected to have headers and transaction data rows.
  """
  def parse(file_stream) do
    file_stream
      |> Parser.parse_stream
      |> Enum.map(fn [date, _, reason, _, _doc, value, _] ->
      # Parse the date string to a NaiveDateTime
      naive_date = Timex.parse!(date, "{0D}/{0M}/{YYYY}")
      # Convert NaiveDateTime to DateTime with UTC timezone
      utc_date = DateTime.from_naive!(naive_date, "Etc/UTC")
      %Transaction{
        datetime: utc_date,
        reason: reason,
        value: String.to_float(value),
        account: nil,
        category: nil
      }
    end)
  end

end
