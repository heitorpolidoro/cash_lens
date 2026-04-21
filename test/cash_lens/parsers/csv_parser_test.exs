defmodule CashLens.CSVParserTest do
  use CashLens.DataCase, async: true
  alias CashLens.Parsers.CSVParser

  @sample_path "test/support/fixtures/files/bb_sample.csv"

  describe "extract_metadata_and_clean/2" do
    test "extracts date and time and cleans description" do
      base_date = ~D[2026-01-01]
      text = "COMPRA NO DEBITO 24/02 14:30 - SUPERMERCADO"

      {date, time, clean_text} = CSVParser.extract_metadata_and_clean(text, base_date)

      assert date == ~D[2026-02-24]
      assert time == ~T[14:30:00]
      assert clean_text == "COMPRA NO DEBITO - SUPERMERCADO"
    end

    test "handles text without date or time" do
      base_date = ~D[2026-01-01]
      text = "TARIFAS BANCARIAS"

      {date, time, clean_text} = CSVParser.extract_metadata_and_clean(text, base_date)

      assert date == base_date
      assert time == nil
      assert clean_text == "TARIFAS BANCARIAS"
    end

    test "handles text with only date" do
      base_date = ~D[2026-01-01]
      text = "TRANSFERENCIA 15/03"

      {date, time, clean_text} = CSVParser.extract_metadata_and_clean(text, base_date)

      assert date == ~D[2026-03-15]
      assert time == nil
      assert clean_text == "TRANSFERENCIA"
    end

    test "handles text with only time" do
      base_date = ~D[2026-01-01]
      text = "OPERACAO ÀS 10:15"

      {date, time, clean_text} = CSVParser.extract_metadata_and_clean(text, base_date)

      assert date == base_date
      assert time == ~T[10:15:00]
      assert clean_text == "OPERACAO ÀS"
    end

    test "cleans leading/trailing separators" do
      base_date = ~D[2026-01-01]
      text = " - . DESC . - "

      {_date, _time, clean_text} = CSVParser.extract_metadata_and_clean(text, base_date)

      assert clean_text == "DESC"
    end
  end

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
      pix = Enum.find(transactions, fn t -> String.contains?(t.description, "TRANSFERENCIA PIX") end)
      assert pix.amount == Decimal.new("-25.50")
      assert pix.date == ~D[2026-02-26]
    end

    test "extracts metadata from complex BB description" do
      # In BB, sometimes the transaction has a generic history like 'PIX - ENVIADO' 
      # but the description column contains 'PIX - ENVIADO 24/02 10:15 CPF: ***.123.456-**'
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n24/02/2026,0,0,PIX - ENVIADO 24/02 10:15 ALGUEM,1,-100.00,\n"
      
      # The parser does Enum.drop(1) which drops the header.
      # If NimbleCSV.parse_string includes the header as the first element, this should work.
      # Wait, bb_sample.csv has a header and it works.
      
      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      tx = List.first(transactions)
      assert tx.date == ~D[2026-02-24]
      assert tx.time == ~T[10:15:00]
      assert tx.description == "PIX - ENVIADO ALGUEM"
    end
  end
end
