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
  def parse(file_stream) when is_binary(file_stream) do
    lines = String.split(file_stream, "\n", trim: true)
    headers = lines |> List.first() |> String.split(",") |> Enum.map(&String.trim(&1, "\""))

    transactions =
      lines
      |> Enum.drop(1)
      |> Enum.map(fn line ->
        values = line |> String.split(",") |> Enum.map(&String.trim(&1, "\""))
        Enum.zip(headers, values) |> Enum.into(%{})
      end)

    %{
      parser: @name,
      encoding: "latin1",
      line_count: length(lines),
      headers: headers,
      transactions: transactions
    }
  end

  def parse(file_stream) do
    file_stream
      |> Parser.parse_stream
      |> Enum.map(fn [date, _, reason, _, _doc, amount, _] ->
      # Parse the date string to a NaiveDateTime
      naive_date = Timex.parse!(date, "{0D}/{0M}/{YYYY}")

      # Handle special case for "Compra com Cartão" with embedded date
      {updated_date, updated_reason} = parse_reason_with_date(reason, naive_date)

      %Transaction{
        datetime: updated_date,
        reason: updated_reason,
        amount: String.to_float(amount),
        account: nil,
        category: nil
      } |> Map.from_struct()
    end)
  end

  @doc """
  Parses a reason string that may contain a date and time.

  If the reason starts with "Compra com Cartão - " followed by a date and time,
  it extracts the date and updates the reason to remove the prefix.

  ## Examples

      iex> parse_reason_with_date("Compra com Cartão - 03/01 15:43 M REIS VARAIS E UTIL", ~N[2025-01-05 00:00:00])
      {~U[2025-01-03 15:43:00Z], "M REIS VARAIS E UTIL"}

      iex> parse_reason_with_date("Regular reason", ~N[2025-01-05 00:00:00])
      {~U[2025-01-05 00:00:00Z], "Regular reason"}

  """
  def parse_reason_with_date(reason, original_date) do
    case Regex.run(~r/^Compra com Cartão - (\d{2})\/(\d{2}) (\d{2}):(\d{2}) (.+)$/, reason) do
      [_, day, month, hour, minute, actual_reason] ->
        # Create a new date with the day, month from the reason, but year from original date
        # Also include the time (hour and minute)
        updated_naive_date = %{original_date |
          day: String.to_integer(day),
          month: String.to_integer(month),
          hour: String.to_integer(hour),
          minute: String.to_integer(minute)
        }
        updated_utc_date = DateTime.from_naive!(updated_naive_date, "Etc/UTC")
        {updated_utc_date, String.trim(actual_reason)}

      nil ->
        # If no match, return the original date and reason
        {DateTime.from_naive!(original_date, "Etc/UTC"), reason}
    end
  end

end
