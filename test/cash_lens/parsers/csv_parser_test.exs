defmodule CashLens.CSVParserTest do
  use CashLens.DataCase, async: false
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

    test "handles invalid time formats gracefully" do
      # 99:99 matches the regex but is an invalid Time
      base_date = ~D[2026-01-01]
      text = "INVALID TIME 99:99"
      {date, time, _} = CSVParser.extract_metadata_and_clean(text, base_date)
      assert date == base_date
      assert time == nil
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
      pix =
        Enum.find(transactions, fn t -> String.contains?(t.description, "TRANSFERENCIA PIX") end)

      assert pix.amount == Decimal.new("-25.50")
      assert pix.date == ~D[2026-02-26]
    end

    test "extracts metadata from complex BB description" do
      # In BB, sometimes the transaction has a generic history like 'PIX - ENVIADO'
      # but the description column contains 'PIX - ENVIADO 24/02 10:15 CPF: ***.123.456-**'
      csv_content =
        "Data,Dep,Term,Hist,Doc,Valor,\n24/02/2026,0,0,PIX - ENVIADO 24/02 10:15 ALGUEM,1,-100.00,\n"

      # We explicitly skip the header in the parser.

      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      tx = List.first(transactions)
      assert tx.date == ~D[2026-02-24]
      assert tx.time == ~T[10:15:00]
      assert tx.description == "PIX - ENVIADO ALGUEM"
    end

    test "handles invalid dates and amounts in parse" do
      # Invalid date and amount string
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\nINVALID,0,0,DESCRIPTION,1,NOT_A_NUMBER,\n"
      transactions = CSVParser.parse(csv_content, :bb)

      # Should return nil for zero amount (NOT_A_NUMBER -> 0)
      assert transactions == []
    end

    test "handles malformed date rescue path" do
      # This date split works but Date.new! would fail if we didn't have the rescue
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n32/01/2026,0,0,DESCRIPTION,1,-10.00,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      # Falls back to Date.utc_today() in rescue
      assert List.first(transactions).date == Date.utc_today()
    end

    test "handles ISO date format in parse_date" do
      # This will hit L96: Date.from_iso8601 success
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n2026-02-24,0,0,DESCRIPTION,1,-10.00,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      assert List.first(transactions).date == ~D[2026-02-24]
    end

    test "handles malformed date that doesn't split by /" do
      # This will hit L108: Date.utc_today fallback
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\nNOT_A_DATE,0,0,DESCRIPTION,1,-10.00,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      assert List.first(transactions).date == Date.utc_today()
    end

    test "parse_row/2 handles rows with incorrect length" do
      # L41: fallback
      assert CSVParser.parse("Data,Dep,Term,Hist,Doc,Valor,Extra,Extra\nshort_row", :bb) == []
    end

    test "parse_amount/1 handles unparseable amount" do
      # L123: :error -> Decimal.new("0")
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n2026-02-24,0,0,DESCRIPTION,1,!!!,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      # amount 0 results in nil
      assert transactions == []
    end

    test "extract_metadata_and_clean handles invalid dates in content" do
      # This will trigger the _ -> base_date branch in final_date
      {date, _time, _clean} = CSVParser.extract_metadata_and_clean("COMPRA 32/13", ~D[2026-01-01])
      assert date == ~D[2026-01-01]
    end

    test "parse_row description handling nil" do
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n2026-02-24,0,0,,1,-10.00,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      assert List.first(transactions).description == ""
    end

    test "handles 2-digit year in slashed date format" do
      csv_content = "Data,Dep,Term,Hist,Doc,Valor,\n01/01/26,0,0,DESCRIPTION,1,-10.00,\n"
      transactions = CSVParser.parse(csv_content, :bb)
      assert length(transactions) == 1
      assert List.first(transactions).date == ~D[2026-01-01]
    end
  end

  describe "parse/2 with :bradesco_csv" do
    @bradesco_header "﻿Data;Histórico;Docto.;Crédito (R$);Débito (R$);Saldo (R$)\n"

    test "parses debits and credits, skipping header and balance rows" do
      content =
        @bradesco_header <>
          "01/03/2026;COMPRA SUPERMERCADO;000123;;120,50;3.000,00\n" <>
          "02/03/2026;DEPOSITO SALARIO;000124;1.500,00;;4.500,00\n" <>
          "03/03/2026;SALDO ANTERIOR;000000;;;3.120,50\n"

      transactions = CSVParser.parse(content, :bradesco_csv)

      assert length(transactions) == 2

      expense = Enum.find(transactions, &(&1.description == "COMPRA SUPERMERCADO"))
      assert expense.amount == Decimal.new("-120.50")
      assert expense.date == ~D[2026-03-01]

      income = Enum.find(transactions, &(&1.description == "DEPOSITO SALARIO"))
      assert income.amount == Decimal.new("1500.00")
      assert income.date == ~D[2026-03-02]

      # The "SALDO ANTERIOR" row is dropped.
      refute Enum.any?(transactions, &String.contains?(&1.description, "SALDO"))
    end

    test "drops rows with zero/unparseable amounts" do
      content =
        @bradesco_header <>
          "01/03/2026;LANCAMENTO INVALIDO;000;abc;xyz;0,00\n"

      assert CSVParser.parse(content, :bradesco_csv) == []
    end

    test "returns empty when there are no date rows" do
      content = @bradesco_header <> "Período: 01/03/2026 a 31/03/2026\n"
      assert CSVParser.parse(content, :bradesco_csv) == []
    end

    test "ignores a date row that has too few columns" do
      # Starts with a valid date (passes the drop_while) but lacks the credit/debit
      # columns, so parse_bradesco_row falls through to its nil clause.
      content = @bradesco_header <> "01/03/2026;APENAS DESCRICAO\n"
      assert CSVParser.parse(content, :bradesco_csv) == []
    end
  end
end
