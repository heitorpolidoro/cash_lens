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
    # Pattern: CFL7G68 Plano Contratado SEM PARAR TURBO 01/11/25 a 30/11/25 28/11/25 R$ 58,17
    # Note: Sometimes the vehicle license plate might be missing or different
    regex = ~r/Plano Contratado\s+.*?\s+(\d{2}\/\d{2}\/\d{2})\s+R\$\s+([\d,.]+)/
    
    case Regex.run(regex, text) do
      [_, date_str, amount_str] ->
        [%{
          date: parse_date(date_str),
          time: nil,
          description: "Mensalidade Sem Parar",
          amount: parse_amount(amount_str) |> Decimal.mult(-1)
        }]
      _ -> []
    end
  end

  defp extract_usages(text) do
    # Looking for lines like: 
    # 06/11/25 às 16:58:35 YORG PARTICIPAÇÕES DO BRASIL LTDA ... R$ 11,00
    # 26/11/25 às 19:38:12 RIOSP JACAREI SUL, CAT. 1 R$ 7,70
    
    # regex matches: date, time, description, amount
    regex = ~r/(\d{2}\/\d{2}\/\d{2})\s+às\s+(\d{2}:\d{2}:\d{2})\s+(.*?)\s+R\$\s+([\d,.]+)/
    
    Regex.scan(regex, text)
    |> Enum.map(fn [_, date_str, time_str, desc, amount_str] ->
      %{
        date: parse_date(date_str),
        time: parse_time(time_str),
        description: String.trim(desc),
        amount: parse_amount(amount_str) |> Decimal.mult(-1)
      }
    end)
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
