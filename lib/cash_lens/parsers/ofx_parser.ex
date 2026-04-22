defmodule CashLens.Parsers.OFXParser do
  @behaviour CashLens.Parsers.Parser
  @moduledoc """
  Parser for OFX (Open Financial Exchange) files.
  Supports standard OFX 1.02/2.x (SGML/XML style).
  """

  @doc """
  Parses an OFX string and returns a list of transaction maps.
  """
  def parse(content, _format) do
    # 1. Split by <STMTTRN> block
    content
    |> String.split("<STMTTRN>", trim: true)
    # Drop the header/metadata part before the first transaction
    |> Enum.drop(1)
    |> Enum.map(&parse_transaction_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_transaction_block(block) do
    # Extract values using regex since OFX can be valid SGML (no closing tags)
    memo = extract_tag(block, "MEMO") || extract_tag(block, "NAME")
    amount = extract_tag(block, "TRNAMT")
    date_str = extract_tag(block, "DTPOSTED")

    if memo && amount && date_str do
      {date, time} = parse_ofx_date(date_str)

      %{
        description: String.trim(memo),
        amount: parse_decimal(amount),
        date: date,
        time: time
      }
    else
      nil
    end
  end

  defp extract_tag(block, tag) do
    # Matches <TAG>VALUE or <TAG>VALUE</TAG>
    pattern = ~r/<#{tag}>(.*?)(?:<|$)/s

    case Regex.run(pattern, block) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_ofx_date(date_str) do
    # OFX Date format: YYYYMMDDHHMMSS
    year = String.slice(date_str, 0..3) |> String.to_integer()
    month = String.slice(date_str, 4..5) |> String.to_integer()
    day = String.slice(date_str, 6..7) |> String.to_integer()

    date = Date.new!(year, month, day)

    time =
      if String.length(date_str) >= 12 do
        hour = String.slice(date_str, 8..9) |> String.to_integer()
        min = String.slice(date_str, 10..11) |> String.to_integer()

        sec =
          if String.length(date_str) >= 14,
            do: String.slice(date_str, 12..13) |> String.to_integer(),
            else: 0

        Time.new!(hour, min, sec)
      else
        nil
      end

    {date, time}
  end

  defp parse_decimal(val) do
    val
    |> String.replace(",", ".")
    |> Decimal.new()
  end
end
