defmodule CashLens.Parsers.CSVParser do
  @moduledoc """
  Module to parse financial statement CSV files with support for multiple bank formats.
  """
  alias NimbleCSV.RFC4180, as: CSV

  @doc """
  Parses a CSV string based on the detected format.
  """
  def parse(csv_content, format \\ :generic) do
    csv_content
    |> CSV.parse_string()
    |> Enum.drop(1) # Skip header
    |> Enum.map(fn row -> parse_row(row, format) end)
    |> Enum.reject(&is_nil/1)
  end

  # Banco do Brasil: Data, Dep, Histórico, Data Bal, Doc, Valor, [Empty]
  defp parse_row([date, _dep, description, _bal, _doc, amount | _], :bb) do
    amount_decimal = parse_amount(amount)
    description_up = String.upcase(description || "")

    # Ignore summary rows and zero amounts
    if Decimal.eq?(amount_decimal, 0) or String.contains?(description_up, ["SALDO", "S A L D O"]) do
      nil
    else
      # Extract better date and time from description if available
      {final_date, final_time} = extract_metadata(description, parse_date(date))

      %{
        date: final_date,
        time: final_time,
        description: description,
        amount: amount_decimal
      }
    end
  end

  # Nubank: Data, Valor, Identificador, Descrição
  defp parse_row([date, amount, _id, description | _], :nubank) do
    {final_date, final_time} = extract_metadata(description, parse_date(date))
    
    %{
      date: final_date,
      time: final_time,
      description: description,
      amount: parse_amount(amount)
    }
  end

  # Generic: Date, Description, Amount
  defp parse_row([date, description, amount | _rest], :generic) do
    {final_date, final_time} = extract_metadata(description, parse_date(date))

    %{
      date: final_date,
      time: final_time,
      description: description,
      amount: parse_amount(amount)
    }
  end

  defp parse_row(_, _), do: nil

  @doc """
  Extracts date (DD/MM) and time (HH:MM) from a string if they exist.
  Returns {date, time}.
  """
  def extract_metadata(text, base_date) do
    # Regex for DD/MM
    date_match = Regex.run(~r/(\d{2})\/(\d{2})/, text)
    # Regex for HH:MM
    time_match = Regex.run(~r/(\d{2}):(\d{2})/, text)

    final_date = 
      case date_match do
        [_, d, m] -> 
          # Use current year or year from base_date
          Date.new!(base_date.year, String.to_integer(m), String.to_integer(d))
        _ -> base_date
      end

    final_time =
      case time_match do
        [_, h, m] -> 
          case Time.new(String.to_integer(h), String.to_integer(m), 0) do
            {:ok, time} -> time
            _ -> nil
          end
        _ -> nil
      end

    {final_date, final_time}
  end

  defp parse_date(date_string) do
    date_string = String.trim(date_string || "")
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ ->
        # Try DD/MM/YYYY
        case String.split(date_string, "/") do
          [d, m, y] ->
            try do
              Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))
            rescue
              _ -> Date.utc_today()
            end
          _ -> Date.utc_today()
        end
    end
  end

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
