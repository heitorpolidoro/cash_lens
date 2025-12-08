defmodule CashLens.Parsers.BB_CSV do
  @moduledoc """
  Parser for Banco do Brasil CSV statement files.
  """
  @name "BB CSV"

  alias CashLens.Transactions.Transaction
  alias CashLens.StringHelper
  # Using standard library date parsing; no Timex dependency

  # Define a custom parser with comma as separator
  NimbleCSV.define(Parser, separator: ",", escape: "\"")

  def name, do: @name

  @doc """
  Parses a CSV file content and returns structured transaction data.

  The CSV is expected to have headers and transaction data rows.
  """

  #  def parse(file_stream) when is_binary(file_stream) do
  #    lines = String.split(file_stream, "\n", trim: true)
  #    headers = lines |> List.first() |> String.split(",") |> Enum.map(&String.trim(&1, "\""))
  #
  #    transactions =
  #      lines
  #      |> Enum.drop(1)
  #      |> Enum.map(fn line ->
  #        values = line |> String.split(",") |> Enum.map(&String.trim(&1, "\""))
  #        Enum.zip(headers, values) |> Enum.into(%{})
  #      end)
  #
  #    %{
  #      parser: @name,
  #      encoding: "latin1",
  #      line_count: length(lines),
  #      headers: headers,
  #      transactions: transactions
  #    }
  #  end

  def parse_statement(file_path) do
    try do
      transactions =
        file_path
        |> File.stream!()
        |> Stream.map(&:unicode.characters_to_binary(&1, :latin1))
        |> Parser.parse_stream()
        |> Stream.reject(fn
          # Skip header
          ["Data" | _] -> true
          _ -> false
        end)
        |> Stream.reject(fn row ->
          hist = row |> Enum.at(2) |> to_string()

          norm =
            hist
            |> String.downcase()
            |> String.replace(" ", "")

          # Skip balance lines like "Saldo Anterior" and "S A L D O"
          norm == "saldo" or String.contains?(norm, "saldoanterior")
        end)
        |> Stream.map(fn row ->
          date_str = Enum.at(row, 0)
          raw_reason = Enum.at(row, 2)
          amount_str = Enum.at(row, 5)

          # Parse statement date (dd/mm/yyyy) as NaiveDateTime at midnight
          naive_date = parse_statement_date!(date_str)

          {updated_dt, cleaned_reason} = parse_reason_with_date(raw_reason, naive_date)

          # Prepare date and time fields
          date = DateTime.to_date(updated_dt)

          time =
            if updated_dt.hour == 0 and updated_dt.minute == 0 and updated_dt.second == 0 do
              nil
            else
              # Keep time as ISO string to match UI expectations
              Time.new!(updated_dt.hour, updated_dt.minute, updated_dt.second)
              |> Time.to_iso8601()
            end

          amount = Decimal.new(String.trim(amount_str))

          %{
            date: date,
            time: time,
            reason: cleaned_reason,
            type: detect_type(raw_reason),
            category: nil,
            amount: amount,
            full_line: Enum.join(row, " ")
          }
        end)
        |> Enum.to_list()

      {:ok, transactions}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # Parse "dd/mm/yyyy" into NaiveDateTime at 00:00:00
  defp parse_statement_date!(date_str) when is_binary(date_str) do
    [d, m, y] =
      date_str
      |> String.split("/")

    {:ok, date} = Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d))
    NaiveDateTime.new!(date, ~T[00:00:00])
  end

  @doc """
  Parses a reason string that may contain a date and time.

  If the reason starts with "Compra com Cartão - " followed by a date and time,
  it extracts the date and updates the reason to remove the prefix.

  ## Examples

      iex> parse_reason_with_date("03/01 15:43 M REIS VARAIS E UTIL", ~N[2025-01-05 00:00:00])
      {~U[2025-01-03 15:43:00Z], "M REIS VARAIS E UTIL"}

      iex> parse_reason_with_date("Regular reason", ~N[2025-01-05 00:00:00])
      {~U[2025-01-05 00:00:00Z], "Regular reason"}

  """
  def parse_reason_with_date(reason, original_date) do
    case Regex.run(~r/(\d{2})\/(\d{2}) (\d{2}):(\d{2}) (.+)$/, reason) do
      [_, day, month, hour, minute, actual_reason] ->
        # Create a new date with the day, month from the reason, but year from original date
        # Also include the time (hour and minute)
        updated_naive_date = %{
          original_date
          | day: String.to_integer(day),
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

  # Detect a normalized transaction type from the raw reason string
  defp detect_type(raw_reason) when is_binary(raw_reason) do
    r = raw_reason |> StringHelper.normalize_no_accents() |> String.downcase() |> String.trim()

    cond do
      String.starts_with?(r, "compra com cartao") -> "debit_card"
      String.starts_with?(r, "pix - enviado") -> "pix"
      String.starts_with?(r, "pix periodico") -> "recurring_pix"
      String.starts_with?(r, "pix-envio devolvido") or String.starts_with?(r, "pix - envio devolvido") ->
        "returned_pix"
      String.starts_with?(r, "pagamento de boleto") -> "boleto"
      String.starts_with?(r, "pagamento de impostos") -> "taxes"
      String.starts_with?(r, "estorno de debito") -> "debit_refund"
      true -> nil
    end
  end

  defp detect_type(_), do: nil

end
