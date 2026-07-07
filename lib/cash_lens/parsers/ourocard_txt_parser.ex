defmodule CashLens.Parsers.OurocardTXTParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Parser for Banco do Brasil Ourocard credit-card statements in plain-text
  (.txt) form. A line is a transaction iff it starts with a `DD.MM.YYYY`
  date; every other line (headers, category/holder labels, SALDO ANTERIOR,
  SubTotal, Total, separators) lacks a leading date and is skipped.
  """

  # date (glued to the description) · description · Valor R$ · Valor US$
  @line_regex ~r/^(\d{2})\.(\d{2})\.(\d{4})(.+?)\s+(-?[\d.]+,\d{2})\s+-?[\d.]+,\d{2}\s*$/

  @impl true
  def parse(content, _format \\ :ourocard) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&parse_line/1)
  end

  @doc """
  Statement-level metadata from the TXT header: due date (Vencimento), total
  (Total da fatura, stored positive) and competência (first day of the due
  month). Any field is nil when its line is absent.
  """
  def extract_statement_meta(content) do
    due = extract_due_date(content)

    %{
      due_date: due,
      total_a_pagar: extract_total(content),
      competencia: due && Date.beginning_of_month(due)
    }
  end

  defp parse_line(line) do
    case Regex.run(@line_regex, line) do
      [_, d, m, y, desc, value] ->
        with {:ok, date} <-
               Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)),
             amount when not is_nil(amount) <- parse_amount(value) do
          [
            %{
              date: date,
              description: clean_description(desc),
              amount: Decimal.negate(amount),
              time: nil
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp clean_description(desc) do
    desc |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # BR format: "11.938,58" -> remove thousands ".", decimal "," -> "."
  defp parse_amount(str) do
    cleaned = str |> String.replace(".", "") |> String.replace(",", ".")

    case Decimal.parse(cleaned) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp extract_due_date(content) do
    case Regex.run(~r/Vencimento\s*:\s*(\d{2})\.(\d{2})\.(\d{4})/i, content) do
      [_, d, m, y] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_total(content) do
    case Regex.run(~r/Total da fatura\s*:\s*R\$\s*([\d.]+,\d{2})/i, content) do
      [_, value] -> parse_amount(value)
      _ -> nil
    end
  end
end
