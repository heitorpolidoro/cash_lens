# TODO Review
# Test script to verify BBCSVParser functionality without database connection
# Run with: mix run test_parser_no_db.exs

defmodule ParserNoDBTest do
  def run do
    IO.puts("Testing BBCSVParser functionality...")

    # Test empty input
    test_empty_input()

    # Test string input (for test compatibility)
    test_string_input()

    # Test special case with "Compra com Cartão"
    test_special_case()
  end

  defp test_empty_input do
    IO.puts("\n=== Testing empty input ===")
    result = CashLens.Parsers.BBCSVParser.parse("")

    IO.puts("Parser: #{result.parser}")
    IO.puts("Encoding: #{result.encoding}")
    IO.puts("Transactions: #{inspect(result.transactions)}")
    IO.puts("Error: #{result.error}")
  end

  defp test_string_input do
    IO.puts("\n=== Testing string input ===")

    content = """
    Date,Description,Amount
    2023-01-01,Grocery Store,-50.00
    2023-01-02,Salary,1000.00
    """

    result = CashLens.Parsers.BBCSVParser.parse(content)

    IO.puts("Parser: #{result.parser}")
    IO.puts("Encoding: #{result.encoding}")
    IO.puts("Line count: #{result.line_count}")
    IO.puts("Headers: #{inspect(result.headers)}")
    IO.puts("Transaction count: #{length(result.transactions)}")

    # Check first transaction
    first_transaction = Enum.at(result.transactions, 0)
    IO.puts("\nFirst transaction:")
    IO.puts("Date: #{first_transaction["Date"]}")
    IO.puts("Description: #{first_transaction["Description"]}")
    IO.puts("Amount: #{first_transaction["Amount"]}")
  end

  defp test_special_case do
    IO.puts("\n=== Testing special case with 'Compra com Cartão' ===")

    # Sample CSV data with "Compra com Cartão" entries
    csv_data = """
    "Data","Dependencia Origem","Histórico","Data do Balancete","Número do documento","Valor",
    "02/01/2025","5899-8","Compra com Cartão - 01/01 14:53 AUTO POSTO LUCKY","","153589","-164.48",
    "03/01/2025","5899-8","Compra com Cartão - 03/01 15:43 M REIS VARAIS E UTIL","","156615","-35.00",
    "05/01/2025","5899-8","Regular transaction","","123456","-50.00",
    """

    # Convert string to stream for the file_stream version of parse
    {:ok, pid} = StringIO.open(csv_data)
    csv_stream = IO.stream(pid, :line)
    transactions = CashLens.Parsers.BBCSVParser.parse(csv_stream)

    IO.puts("Parsed transactions:")

    Enum.each(transactions, fn transaction ->
      IO.puts("Date: #{inspect(transaction.datetime)}")
      IO.puts("Reason: #{transaction.reason}")
      IO.puts("Value: #{transaction.value}")
      IO.puts("---")
    end)

    # Verify the special case
    special_case = Enum.at(transactions, 1)
    IO.puts("\nVerifying special case:")
    IO.puts("Expected date: 2025-01-03")

    IO.puts(
      "Actual date: #{special_case.datetime.year}-#{pad(special_case.datetime.month)}-#{pad(special_case.datetime.day)}"
    )

    IO.puts("Expected reason: M REIS VARAIS E UTIL")
    IO.puts("Actual reason: #{special_case.reason}")

    if special_case.datetime.year == 2025 &&
         special_case.datetime.month == 1 &&
         special_case.datetime.day == 3 &&
         special_case.reason == "M REIS VARAIS E UTIL" do
      IO.puts("\n✅ Special case handling is working correctly!")
    else
      IO.puts("\n❌ Special case handling is NOT working correctly!")
    end
  end

  defp pad(number) do
    number |> Integer.to_string() |> String.pad_leading(2, "0")
  end
end

ParserNoDBTest.run()
