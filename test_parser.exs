# Simple script to test the BBCSVParser without database connection
# Run with: mix run test_parser.exs

# Load the application code
Code.require_file("lib/cash_lens/parsers/bb_csv_parser.ex")

# Sample CSV content
csv_content = """
Date,Description,Amount
2023-01-01,Grocery Store,-50.00
2023-01-02,Salary,1000.00
"""

# Parse the CSV content
result = CashLens.Parsers.BBCSVParser.parse(csv_content)

# Print the result
IO.puts("Parser: #{result.parser}")
IO.puts("Encoding: #{result.encoding}")
IO.puts("Line count: #{result.line_count}")
IO.puts("Headers: #{inspect(result.headers)}")
IO.puts("Transactions count: #{length(result.transactions)}")
IO.puts("\nFirst transaction: #{inspect(Enum.at(result.transactions, 0))}")
IO.puts("\nSecond transaction: #{inspect(Enum.at(result.transactions, 1))}")
