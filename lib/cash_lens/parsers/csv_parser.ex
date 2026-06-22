defmodule CashLens.Parsers.CSVParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Module to parse financial statement CSV files with support for multiple bank formats.
  """
  alias NimbleCSV.RFC4180, as: CSV
  NimbleCSV.define(CashLens.Parsers.CSVParser.Semicolon, separator: ";", escape: "\"")
  alias CashLens.Parsers.CSVParser.Semicolon

  @doc """
  Parses a CSV string. Supported formats:
  - `:bradesco_csv` — Bradesco bank statement (semicolon-separated, BOM prefix)
  - `:bb` — Banco do Brasil (comma or semicolon)
  - `:mercado_pago_csv` — Mercado Pago bank statement (semicolon-separated)
  """
  def parse(csv_content, :bradesco_csv) do
    csv_content
    |> String.replace("﻿", "")
    |> Semicolon.parse_string(skip_headers: false)
    |> Enum.drop_while(&(not bradesco_date_row?(&1)))
    |> Enum.map(&parse_bradesco_row/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(csv_content, :mercado_pago_csv) do
    csv_content
    |> Semicolon.parse_string(skip_headers: false)
    |> Enum.drop_while(&(not mercado_pago_header_row?(&1)))
    |> Enum.drop(1)
    |> Enum.map(&parse_mercado_pago_row/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(csv_content, :bb) do
    # Banco do Brasil often exports with semicolons depending on the locale
    parser =
      if String.contains?(csv_content, "\";\"") or String.contains?(csv_content, ";"),
        do: Semicolon,
        else: CSV

    case csv_content |> parser.parse_string(skip_headers: false) |> Enum.to_list() do
      [header | rows] ->
        mapping = bb_column_mapping(header)

        rows
        |> Enum.map(&parse_bb_row(&1, mapping))
        |> Enum.reject(&is_nil/1)

      [] ->
        []
    end
  end

  # --- Bradesco helpers ---

  defp bradesco_date_row?([date | _]),
    do: Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, String.trim(date))

  # coveralls-ignore-next-line
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

  # BB has changed its CSV export layout over time (column count and order vary
  # between exports — e.g. a "Histórico" column some years, a split
  # "Lançamento"/"Detalhes" pair in others, with "Valor" moving accordingly). Reading
  # column positions by header name (instead of a fixed index/heuristic) makes every
  # variant resolve to the same fields without needing per-format detection.
  defp bb_column_mapping(header) do
    normalized = Enum.map(header, &normalize_header/1)

    %{
      date_idx: find_col(normalized, "data") || 0,
      valor_idx: find_col(normalized, "valor"),
      historico_idx: find_col(normalized, "hist"),
      lancamento_idx: find_col(normalized, "lancamento"),
      detalhes_idx: find_col(normalized, "detalhes")
    }
  end

  # Headers are sometimes abbreviated ("Hist" instead of "Histórico") and the
  # exact wording varies by export, so match by substring rather than equality.
  # First match wins, which is what disambiguates e.g. "Lançamento" (idx 1) from
  # "Tipo Lançamento" (idx 5) — the real column always comes first in BB exports.
  defp find_col(normalized, needle),
    do: Enum.find_index(normalized, &String.contains?(&1, needle))

  defp normalize_header(header) do
    (header || "")
    |> String.trim()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z]/u, "")
  end

  defp parse_bb_row(row, mapping) do
    date = Enum.at(row, mapping.date_idx)
    amount = if mapping.valor_idx, do: Enum.at(row, mapping.valor_idx)
    description = bb_row_description(row, mapping)

    do_parse_row(date, description, amount)
  end

  defp bb_row_description(row, %{historico_idx: idx}) when not is_nil(idx) do
    Enum.at(row, idx)
  end

  defp bb_row_description(row, %{lancamento_idx: l_idx, detalhes_idx: d_idx}) do
    [l_idx, d_idx]
    |> Enum.map(&if &1, do: Enum.at(row, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
  end

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

  # BB exports amounts in two different notations depending on the statement:
  # plain "-150.00" (no thousands separator) in some exports, and Brazilian
  # "-1.471,52" (period thousands separator, comma decimal) in others. A comma
  # is the tell: when present, the period(s) before it are thousands separators
  # and must be dropped, not converted, or "1.471,52" round-trips to the
  # invalid "1.471.52" and silently zeroes out the transaction.
  defp parse_amount(amount_string) do
    raw = (amount_string || "") |> String.trim() |> String.replace(~r/[^0-9,.-]/, "")

    clean_string =
      if String.contains?(raw, ",") do
        raw |> String.replace(".", "") |> String.replace(",", ".")
      else
        raw
      end

    case Decimal.cast(clean_string) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  # --- Mercado Pago helpers ---

  defp mercado_pago_header_row?([first | _]) do
    String.trim(first || "") == "RELEASE_DATE"
  end

  defp mercado_pago_header_row?(_), do: false

  defp parse_mercado_pago_row([date_str, type_str, _ref_id, amount_str | _]) do
    date = parse_dash_date(String.trim(date_str))
    amount = parse_br_amount(amount_str)
    clean_desc = String.trim(type_str)

    if is_nil(date) or Decimal.eq?(amount, Decimal.new("0")) do
      nil
    else
      %{date: date, time: nil, description: clean_desc, amount: amount}
    end
  end

  defp parse_mercado_pago_row(_), do: nil

  defp parse_dash_date(date_string) do
    case String.split(date_string, "-") do
      [d, m, y] ->
        with {d_i, ""} <- Integer.parse(d),
             {m_i, ""} <- Integer.parse(m),
             {y_i, ""} <- Integer.parse(y),
             {:ok, date} <- Date.new(y_i, m_i, d_i) do
          date
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
