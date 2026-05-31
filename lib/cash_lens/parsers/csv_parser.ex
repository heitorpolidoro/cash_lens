defmodule CashLens.Parsers.CSVParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Module to parse financial statement CSV files with support for multiple bank formats.
  """
  alias NimbleCSV.RFC4180, as: CSV
  NimbleCSV.define(CashLens.Parsers.CSVParser.Semicolon, separator: ";", escape: "\"")

  @doc """
  Parses a CSV string. Supported formats:
  - `:bradesco_csv` — Bradesco bank statement (semicolon-separated, BOM prefix)
  - `:bb` — Banco do Brasil (comma or semicolon)
  """
  def parse(csv_content, :bradesco_csv) do
    csv_content
    |> String.replace("﻿", "")
    |> CashLens.Parsers.CSVParser.Semicolon.parse_string(skip_headers: false)
    |> Enum.drop_while(&(not bradesco_date_row?(&1)))
    |> Enum.map(&parse_bradesco_row/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(csv_content, :bb) do
    # Banco do Brasil often exports with semicolons depending on the locale
    parser =
      if String.contains?(csv_content, "\";\"") or String.contains?(csv_content, ";"),
        do: CashLens.Parsers.CSVParser.Semicolon,
        else: CSV

    csv_content
    |> parser.parse_string(skip_headers: false)
    |> Enum.drop(1)
    |> Enum.map(fn row -> parse_row(row, :bb) end)
    |> Enum.reject(&is_nil/1)
  end

  # --- Bradesco helpers ---

  defp bradesco_date_row?([date | _]),
    do: Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, String.trim(date))

  defp bradesco_date_row?(_), do: false

  # Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)
  defp parse_bradesco_row([raw_date, description, _docto, credit_str, debit_str | _]) do
    date_str = String.trim(raw_date)

    with true <- Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, date_str),
         date <- parse_slashed_date(date_str),
         credit <- parse_br_amount(credit_str),
         debit <- parse_br_amount(debit_str),
         amount <- resolve_bradesco_amount(credit, debit),
         false <- Decimal.eq?(amount, Decimal.new("0")),
         clean_desc <- String.trim(description),
         false <- skip_bradesco_description?(clean_desc) do
      %{date: date, time: nil, description: clean_desc, amount: amount}
    else
      _ -> nil
    end
  end

  defp parse_bradesco_row(_), do: nil

  defp resolve_bradesco_amount(credit, debit) do
    cond do
      not Decimal.eq?(credit, Decimal.new("0")) -> credit
      not Decimal.eq?(debit, Decimal.new("0")) -> Decimal.negate(debit)
      true -> Decimal.new("0")
    end
  end

  defp skip_bradesco_description?(desc) do
    upper = String.upcase(desc)
    String.contains?(upper, ["SALDO", "S A L D O", "COD. LANC. 0", "ÚLTIMOS LANC"])
  end

  # Parses Brazilian number format: "3.591,96" → Decimal 3591.96
  defp parse_br_amount(str) do
    clean =
      (str || "")
      |> String.trim()
      |> String.replace(".", "")
      |> String.replace(",", ".")

    case Decimal.cast(clean) do
      {:ok, d} -> d
      :error -> Decimal.new("0")
    end
  end

  # --- Banco do Brasil helpers ---

  # Try to match based on row length to handle different exports
  defp parse_row(row, :bb) when length(row) >= 6 do
    description = Enum.at(row, 2)
    amount = Enum.at(row, 5)

    # Heuristic: if column 3 (index 2) is a small number and column 4 exists,
    # it might be the Dep/Term format
    {description, amount} =
      if String.match?(description || "", ~r/^\d+$/) and length(row) >= 6 do
        {Enum.at(row, 3), Enum.at(row, 5)}
      else
        {description, amount}
      end

    do_parse_row(Enum.at(row, 0), description, amount)
  end

  defp parse_row(_, _), do: nil

  defp do_parse_row(date, description, amount) do
    amount_decimal = parse_amount(amount)
    description_val = description || ""
    description_up = String.upcase(description_val)

    # Ignore summary rows and zero amounts
    if Decimal.eq?(amount_decimal, 0) or String.contains?(description_up, ["SALDO", "S A L D O"]) do
      nil
    else
      {final_date, final_time, clean_description} =
        extract_metadata_and_clean(description_val, parse_date(date))

      %{
        date: final_date,
        time: final_time,
        description: clean_description,
        amount: amount_decimal
      }
    end
  end

  # --- Shared helpers ---

  @doc """
  Extracts date (DD/MM) and time (HH:MM) from a string and returns a cleaned version.
  Returns {date, time, clean_text}.
  """
  def extract_metadata_and_clean(text, base_date) do
    date_match = Regex.run(~r/(\d{2})\/(\d{2})/, text)
    time_match = Regex.run(~r/(\d{2}):(\d{2})/, text)

    final_date =
      case date_match do
        [_, d, m] ->
          case Date.new(base_date.year, String.to_integer(m), String.to_integer(d)) do
            {:ok, date} -> date
            _ -> base_date
          end

        _ ->
          base_date
      end

    final_time =
      case time_match do
        [_, h, m] ->
          case Time.new(String.to_integer(h), String.to_integer(m), 0) do
            {:ok, time} -> time
            _ -> nil
          end

        _ ->
          nil
      end

    clean_text =
      text
      |> String.replace(~r/\d{2}\/\d{2}/, "")
      |> String.replace(~r/\d{2}:\d{2}/, "")
      |> String.replace(~r/^[\s\-\.]+/, "")
      |> String.replace(~r/[\s\-\.]+$/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    {final_date, final_time, clean_text}
  end

  defp parse_date(date_string) do
    date_string = String.trim(date_string || "")

    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> parse_slashed_date(date_string)
    end
  end

  defp parse_slashed_date(date_string) do
    case String.split(date_string, "/") do
      [d, m, y] ->
        with {d_int, ""} <- Integer.parse(d),
             {m_int, ""} <- Integer.parse(m),
             {y_int, ""} <- Integer.parse(y),
             {:ok, date} <- Date.new(normalize_year(y_int), m_int, d_int) do
          date
        else
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end

  defp normalize_year(y) when y < 100, do: 2000 + y
  defp normalize_year(y), do: y

  defp parse_amount(amount_string) do
    clean_string =
      (amount_string || "")
      |> String.trim()
      |> String.replace(~r/[^0-9,.-]/, "")
      |> String.replace(",", ".")

    case Decimal.cast(clean_string) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end
end
