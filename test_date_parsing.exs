# TODO Review
# Test script to verify date parsing in BBCSVParser
# Run with: mix run test_date_parsing.exs

defmodule DateParsingTest do
  def run do
    IO.puts("Testing BBCSVParser date parsing...")

    # Sample CSV data with dates in DD/MM/YYYY format
    csv_data = """
    "Data","Dependencia Origem","Histórico","Data do Balancete","Número do documento","Valor",
    "31/12/2024","","Saldo Anterior","","0","0.00",
    "02/01/2025","5899-8","Compra com Cartão - 01/01 14:53 AUTO POSTO LUCKY","","153589","-164.48",
    "03/01/2025","5899-8","Compra com Cartão - 03/01 15:43 M REIS VARAIS E UTIL","","156615","-35.00",
    "05/01/2025","5899-8","Regular transaction","","123456","-50.00",
    """

    try do
      # Parse the CSV data
      IO.puts("Parsing CSV data...")
      # Convert string to stream
      {:ok, pid} = StringIO.open(csv_data)
      csv_stream = IO.stream(pid, :line)
      transactions = CashLens.Parsers.BBCSVParser.parse(csv_stream)

      # Print the results
      IO.puts("\nParsed transactions:")

      Enum.each(transactions, fn transaction ->
        IO.puts("Date: #{inspect(transaction.datetime)} (#{typeof(transaction.datetime)})")
        IO.puts("Reason: #{transaction.reason}")
        IO.puts("Value: #{transaction.value}")
        IO.puts("---")
      end)

      # Verify time inclusion for the special case
      # "Compra com Cartão - 03/01 15:43 M REIS VARAIS E UTIL"
      special_case = Enum.at(transactions, 2)
      IO.puts("\nVerifying time inclusion:")
      IO.puts("Expected time: 15:43")

      IO.puts(
        "Actual time: #{pad(special_case.datetime.hour)}:#{pad(special_case.datetime.minute)}"
      )

      if special_case.datetime.hour == 15 && special_case.datetime.minute == 43 do
        IO.puts("✅ Time is correctly included in the datetime!")
      else
        IO.puts("❌ Time is NOT correctly included in the datetime!")
      end
    rescue
      e ->
        IO.puts("Error: #{inspect(e)}")
        IO.puts("Stacktrace:")
        IO.puts(Exception.format_stacktrace(__STACKTRACE__))
    end
  end

  defp typeof(x) do
    cond do
      is_binary(x) -> "String"
      is_integer(x) -> "Integer"
      is_float(x) -> "Float"
      is_boolean(x) -> "Boolean"
      is_atom(x) -> "Atom"
      is_list(x) -> "List"
      is_tuple(x) -> "Tuple"
      is_map(x) -> "Map"
      is_function(x) -> "Function"
      is_pid(x) -> "PID"
      is_port(x) -> "Port"
      is_reference(x) -> "Reference"
      true -> "Unknown"
    end
  end

  # Helper function to pad single-digit numbers with a leading zero
  defp pad(number) do
    number |> Integer.to_string() |> String.pad_leading(2, "0")
  end
end

DateParsingTest.run()
