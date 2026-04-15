defmodule CashLens.Parsers.CSVParser do
  @moduledoc """
  Module to parse financial statement CSV files with support for multiple bank formats.
  """
  alias NimbleCSV.RFC4180, as: CSV

  @doc """
  Parses a CSV string for Banco do Brasil format.
  """
  def parse(csv_content, :bb) do
    csv_content
    |> CSV.parse_string()
    |> Enum.drop(1) # Skip header
    |> Enum.map(fn row -> parse_row(row, :bb) end)
    |> Enum.reject(&is_nil/1)
  end

  # Banco do Brasil: Data, Dep, Term, Histórico, Doc, Valor, [Empty]
  defp parse_row([date, _dep, _term, description, _doc, amount | _], :bb) do
    amount_decimal = parse_amount(amount)
    description_up = String.upcase(description || "")

    # Ignore summary rows and zero amounts
    if Decimal.eq?(amount_decimal, 0) or String.contains?(description_up, ["SALDO", "S A L D O"]) do
      nil
    else
      # Extract metadata and CLEAN description
      {final_date, final_time, clean_description} = extract_metadata_and_clean(description, parse_date(date))

      %{
        date: final_date,
        time: final_time,
        description: clean_description,
        amount: amount_decimal
      }
    end
  end

  defp parse_row(_, _), do: nil

  @doc """
  Extracts date (DD/MM) and time (HH:MM) from a string and returns a cleaned version of the string.
  Returns {date, time, clean_text}.
  """
  def extract_metadata_and_clean(text, base_date) do
    # Regex for DD/MM and HH:MM
    date_match = Regex.run(~r/(\d{2})\/(\d{2})/, text)
    time_match = Regex.run(~r/(\d{2}):(\d{2})/, text)

    final_date = 
      case date_match do
        [_, d, m] -> 
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

    # CLEANING: Remove date, time, and common separators that become trailing/leading
    clean_text = 
      text
      |> String.replace(~r/\d{2}\/\d{2}/, "")   # Remove DD/MM
      |> String.replace(~r/\d{2}:\d{2}/, "")   # Remove HH:MM
      |> String.replace(~r/^[\s\-\.]+/, "")    # Remove leading dashes/dots/spaces
      |> String.replace(~r/[\s\-\.]+$/, "")    # Remove trailing dashes/dots/spaces
      |> String.replace(~r/\s+/, " ")          # Normalize spaces
      |> String.trim()

    {final_date, final_time, clean_text}
  end

  defp parse_date(date_string) do
    date_string = String.trim(date_string || "")
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ ->
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
