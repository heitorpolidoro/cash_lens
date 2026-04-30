defmodule CashLens.Parsers.PDFParser do
  @behaviour CashLens.Parsers.Parser
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
    regex = ~r/Plano Contratado.*?(\d{2}\/\d{2}\/\d{2}|[A-Z_]+)\s+R\$\s+([\d,.]+)/s

    Regex.scan(regex, text)
    |> Enum.map(fn [_, date_str, amount_str] ->
      %{
        date: parse_date(date_str),
        time: nil,
        description: "Mensalidade Sem Parar",
        amount:
          parse_amount(amount_str)
          |> (fn amt ->
                if Decimal.eq?(amt, 0), do: Decimal.new("0"), else: Decimal.mult(amt, -1)
              end).()
      }
    end)
  end

  defp extract_usages(text) do
    lines = String.split(text, "\n")

    # regex for line 1: optional vehicle plate, date, description, amount
    regex_l1 =
      ~r/^(?!.*Plano Contratado)(?:[A-Z0-9]{7})?\s*(\d{2}\/\d{2}\/\d{2}|[A-Z_]+)\s+(.*?)\s+R\$\s+([\d,.]+)/

    # regex for line 2: "às" time, more description
    regex_l2 = ~r/\s+às\s+(\d{2}:\d{2}:\d{2}|[A-Z_]+)\s+(.*)/

    {transactions, last_tx} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, last_tx} ->
        cond do
          # 1. Matches line 1 (New Transaction starting)
          Regex.match?(regex_l1, line) ->
            [_, date_str, desc, amount_str] = Regex.run(regex_l1, line)

            new_tx = %{
              date: parse_date(date_str),
              time: nil,
              description: String.trim(desc),
              amount:
                parse_amount(amount_str)
                |> (fn amt ->
                      if Decimal.eq?(amt, 0), do: Decimal.new("0"), else: Decimal.mult(amt, -1)
                    end).()
            }

            # If there was a previous tx, save it now
            acc = if last_tx, do: [last_tx | acc], else: acc
            {acc, new_tx}

          # 2. Matches line 2 (Continuing last transaction)
          last_tx && Regex.match?(regex_l2, line) ->
            [_, time_str, extra_desc] = Regex.run(regex_l2, line)

            updated_tx = %{
              last_tx
              | time: parse_time(time_str),
                description:
                  (last_tx.description <> " " <> String.trim(extra_desc)) |> String.trim()
            }

            # Finish this TX and add to list
            {[updated_tx | acc], nil}

          # 3. Random line, if we have a pending TX, we keep it as it might be a single-line TX
          # or it might get an "às" line next.
          true ->
            {acc, last_tx}
        end
      end)

    # Final flush
    final_acc = if last_tx, do: [last_tx | transactions], else: transactions
    final_acc |> Enum.reverse()
  end

  defp parse_date(date_string) do
    case String.split(date_string, "/") do
      [d, m, y] ->
        year = 2000 + String.to_integer(y)
        Date.new!(year, String.to_integer(m), String.to_integer(d))

      _ ->
        Date.utc_today()
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
