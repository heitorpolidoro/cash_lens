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
    # Use case-insensitive regex scan for STMTTRN blocks
    # This is more robust than splitting as it focuses on the blocks themselves
    # Matches from <STMTTRN> until the next <STMTTRN> or the end of string
    ~r/<STMTTRN>(.*?)(?=<STMTTRN>|$)/si
    |> Regex.scan(content)
    |> Enum.map(fn [_, block] -> parse_transaction_block(block) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_transaction_block(block) do
    # Extract values using regex (case-insensitive for tags)
    memo = extract_tag(block, "MEMO") || extract_tag(block, "NAME")
    amount_str = extract_tag(block, "TRNAMT")
    date_str = extract_tag(block, "DTPOSTED")

    with {:ok, amount} <- parse_decimal(amount_str),
         {:ok, {date, time}} <- parse_ofx_date(date_str) do
      %{
        description: if(memo, do: String.trim(memo), else: "UNKNOWN"),
        amount: amount,
        date: date,
        time: time
      }
    else
      _ -> nil
    end
  end

  defp extract_tag(block, tag) do
    # Matches <TAG>VALUE or <TAG>VALUE</TAG> case-insensitively
    # Use non-greedy with character class to prevent catastrophic backtracking
    pattern = ~r/<#{tag}>([^<>]*?)(?:<|$)/si

    case Regex.run(pattern, block) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_ofx_date(nil), do: :error

  defp parse_ofx_date(date_str) do
    # OFX Date format: YYYYMMDDHHMMSS
    with {:ok, year} <- safe_to_integer(String.slice(date_str, 0..3)),
         {:ok, month} <- safe_to_integer(String.slice(date_str, 4..5)),
         {:ok, day} <- safe_to_integer(String.slice(date_str, 6..7)),
         {:ok, date} <- Date.new(year, month, day) do
      time =
        with {:ok, hour} <- safe_to_integer(String.slice(date_str, 8..9)),
             {:ok, min} <- safe_to_integer(String.slice(date_str, 10..11)),
             sec = extract_seconds(date_str),
             {:ok, time} <- Time.new(hour, min, sec) do
          time
        else
          _ -> nil
        end

      {:ok, {date, time}}
    else
      _ -> :error
    end
  end

  defp extract_seconds(date_str) do
    sec_str = String.slice(date_str, 12..13)

    case safe_to_integer(sec_str) do
      {:ok, s} -> s
      _ -> 0
    end
  end

  defp parse_decimal(nil), do: :error

  defp parse_decimal(val) do
    cleaned = String.replace(val, ",", ".")

    case Decimal.parse(cleaned) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp safe_to_integer(str) do
    case Integer.parse(str) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end
end
