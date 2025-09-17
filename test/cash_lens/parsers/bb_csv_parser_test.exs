# TODO Review
defmodule CashLens.Parsers.BBCSVParserTest do
  use ExUnit.Case, async: true

  alias CashLens.Parsers.BBCSVParser

  describe "name/0" do
    test "returns the parser name" do
      assert BBCSVParser.name() == "BB CSV"
    end
  end

  describe "parse/1" do
    test "returns empty transactions list when content is empty" do
      result = BBCSVParser.parse("")

      assert result.parser == "BB CSV"
      assert result.encoding == "latin1"
      assert result.transactions == []
      assert result.error == "No data found in file"
    end

    test "parses CSV content with headers and data rows" do
      content = """
      Date,Description,Amount
      2023-01-01,Grocery Store,-50.00
      2023-01-02,Salary,1000.00
      """

      result = BBCSVParser.parse(content)

      assert result.parser == "BB CSV"
      assert result.encoding == "latin1"
      assert result.line_count == 3
      assert result.headers == ["Date", "Description", "Amount"]
      assert length(result.transactions) == 2

      # Check first transaction
      first_transaction = Enum.at(result.transactions, 0)
      assert first_transaction["Date"] == "2023-01-01"
      assert first_transaction["Description"] == "Grocery Store"
      assert first_transaction["Amount"] == "-50.00"

      # Check second transaction
      second_transaction = Enum.at(result.transactions, 1)
      assert second_transaction["Date"] == "2023-01-02"
      assert second_transaction["Description"] == "Salary"
      assert second_transaction["Amount"] == "1000.00"
    end
  end
end
