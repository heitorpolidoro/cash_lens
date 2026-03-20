defmodule CashLens.Parsers.PDFParser do
  @moduledoc """
  Parser for PDF content (text-based) for various providers.
  """

  @doc """
  Parses the text content of a PDF statement.
  """
  def parse(text, :sem_parar) do
    # 1. Extract Plan/Monthly Fee
    plan_transactions = extract_plan_fee(text)
    
    # 2. Extract Usages (Tolls, Parking, etc.)
    usage_transactions = extract_usages(text)

    plan_transactions ++ usage_transactions
  end

  defp extract_plan_fee(text) do
    # Pattern: Plano Contratado ... R$ 58,17
    # Using scan to ensure we get all (though usually it's just one)
    regex = ~r/Plano Contratado.*?(\d{2}\/\d{2}\/\d{2})\s+R\$\s+([\d,.]+)/s
    
    Regex.scan(regex, text)
    |> Enum.map(fn [_, date_str, amount_str] ->
      %{
        date: parse_date(date_str),
        time: nil,
        description: "Mensalidade Sem Parar",
        amount: parse_amount(amount_str) |> Decimal.mult(-1)
      }
    end)
  end

  defp extract_usages(text) do
    lines = String.split(text, "\n")
    
    # regex for line 1: optional vehicle plate, date, description, amount
    # Example: CFL7G68                                      26/11/25         RIOSP                                                             R$ 7,70
    regex_l1 = ~r/(?:[A-Z0-9]{7})?\s*(\d{2}\/\d{2}\/\d{2})\s+(.*?)\s+R\$\s+([\d,.]+)/
    
    # regex for line 2: "às" time, more description
    # Example:                                               às 19:38:12      JACAREI SUL, CAT. 1
    regex_l2 = ~r/\s+às\s+(\d{2}:\d{2}:\d{2})\s+(.*)/

    {transactions, _} = Enum.reduce(lines, {[], nil}, fn line, {acc, last_tx} ->
      cond do
        # 1. Matches line 1 (New Transaction starting)
        Regex.match?(regex_l1, line) ->
          [_, date_str, desc, amount_str] = Regex.run(regex_l1, line)
          
          new_tx = %{
            date: parse_date(date_str),
            time: nil,
            description: String.trim(desc),
            amount: parse_amount(amount_str) |> Decimal.mult(-1)
          }
          {acc, new_tx}

        # 2. Matches line 2 (Continuing last transaction)
        last_tx && Regex.match?(regex_l2, line) ->
          [_, time_str, extra_desc] = Regex.run(regex_l2, line)
          
          updated_tx = %{last_tx | 
            time: parse_time(time_str),
            description: (last_tx.description <> " " <> String.trim(extra_desc)) |> String.trim()
          }
          {[updated_tx | acc], nil} # Finish this TX and add to list

        # 3. Random line, if we have a pending TX that didn't get a "line 2", 
        # we might want to save it or discard it. In Sem Parar, they usually come in pairs.
        true ->
          {acc, last_tx}
      end
    end)

    transactions |> Enum.reverse()
  end

  defp parse_date(date_string) do
    case String.split(date_string, "/") do
      [d, m, y] ->
        year = 2000 + String.to_integer(y)
        Date.new!(year, String.to_integer(m), String.to_integer(d))
      _ -> Date.utc_today()
    end
  end

  defp parse_time(time_string) do
    case String.split(time_string, ":") do
      [h, m, s] -> Time.new!(String.to_integer(h), String.to_integer(m), String.to_integer(s))
      _ -> nil
    end
  end

  defp parse_amount(amount_string) do
    clean_string =
      amount_string
      |> String.replace(".", "")
      |> String.replace(",", ".")

    case Decimal.cast(clean_string) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end
end
