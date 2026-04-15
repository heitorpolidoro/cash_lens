defmodule CashLens.CSVParserTest do
  use CashLens.DataCase, async: true
  alias CashLens.Parsers.CSVParser

  @sample_path "test/support/fixtures/files/bb_sample.csv"

  describe "parse/2" do
    test "correctly parses a Banco do Brasil CSV file" do
      csv_content = File.read!(@sample_path)
      transactions = CSVParser.parse(csv_content, :bb)

      # We expect 3 real transactions (skipping SALDO ANTERIOR and SALDO DO DIA)
      assert length(transactions) == 3

      # Test a negative transaction (Expense)
      ouro = Enum.find(transactions, fn t -> t.description == "BB MM OURO" end)
      assert ouro.amount == Decimal.new("-150.00")
      assert ouro.date == ~D[2026-02-24]

      # Test a positive transaction (Income/Transfer)
      rende = Enum.find(transactions, fn t -> t.description == "BB RENDE FACIL" end)
      assert rende.amount == Decimal.new("500.00")
      assert rende.date == ~D[2026-02-25]

      # Test a PIX transaction
      pix = Enum.find(transactions, fn t -> t.description == "TRANSFERENCIA PIX" end)
      assert pix.amount == Decimal.new("-25.50")
      assert pix.date == ~D[2026-02-26]
    end
  end
end
