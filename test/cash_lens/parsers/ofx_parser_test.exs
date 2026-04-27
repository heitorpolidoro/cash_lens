defmodule CashLens.Parsers.OFXParserTest do
  use CashLens.DataCase, async: true
  alias CashLens.Parsers.OFXParser

  @sample_ofx """
  OFXHEADER:100
  DATA:OFXSGML
  VERSION:102
  SECURITY:NONE
  ENCODING:USASCII
  CHARSET:1252
  COMPRESSION:NONE
  OLDFILEUID:NONE
  NEWFILEUID:NONE

  <OFX>
  <BANKMSGSRSV1>
  <STMTTRNRS>
  <STMTRS>
  <CURDEF>BRL</CURDEF>
  <BANKTRANLIST>
  <DTSTART>20260401000000</DTSTART>
  <DTEND>20260421000000</DTEND>
  <STMTTRN>
  <TRNTYPE>DEBIT</TRNTYPE>
  <DTPOSTED>20260410120000</DTPOSTED>
  <TRNAMT>-150.00</TRNAMT>
  <FITID>20260410001</FITID>
  <CHECKNUM>001</CHECKNUM>
  <MEMO>COMPRA SUPERMERCADO</MEMO>
  </STMTTRN>
  <STMTTRN>
  <TRNTYPE>CREDIT</TRNTYPE>
  <DTPOSTED>20260415103000</DTPOSTED>
  <TRNAMT>1200.50</TRNAMT>
  <FITID>20260415002</FITID>
  <MEMO>TRANSFERENCIA RECEBIDA</MEMO>
  </STMTTRN>
  </BANKTRANLIST>
  </STMTRS>
  </STMTTRNRS>
  </BANKMSGSRSV1>
  </OFX>
  """

  describe "parse/2" do
    test "correctly parses a standard OFX string" do
      transactions = OFXParser.parse(@sample_ofx, :standard)

      assert length(transactions) == 2

      t1 = Enum.find(transactions, fn t -> t.description == "COMPRA SUPERMERCADO" end)
      assert t1.amount == Decimal.new("-150.00")
      assert t1.date == ~D[2026-04-10]
      assert t1.time == ~T[12:00:00]

      t2 = Enum.find(transactions, fn t -> t.description == "TRANSFERENCIA RECEBIDA" end)
      assert t2.amount == Decimal.new("1200.50")
      assert t2.date == ~D[2026-04-15]
      assert t2.time == ~T[10:30:00]
    end

    test "handles empty or invalid content" do
      assert OFXParser.parse("", :standard) == []
      assert OFXParser.parse("NO TRANSACTIONS HERE", :standard) == []
    end

    test "handles malformed transaction blocks" do
      malformed = """
      <STMTTRN>
      <TRNAMT>INVALID</TRNAMT>
      <DTPOSTED>20260410120000</DTPOSTED>
      <MEMO>INVALID AMOUNT</MEMO>
      </STMTTRN>
      <STMTTRN>
      <TRNAMT>100.00</TRNAMT>
      <DTPOSTED>INVALID_DATE</DTPOSTED>
      <MEMO>INVALID DATE</MEMO>
      </STMTTRN>
      """

      assert OFXParser.parse(malformed, :standard) == []
    end

    test "handles different date and time lengths" do
      # Date without time, and date with short time
      content = """
      <STMTTRN>
      <TRNAMT>50.00</TRNAMT>
      <DTPOSTED>20260410</DTPOSTED>
      <NAME>ONLY DATE</NAME>
      </STMTTRN>
      <STMTTRN>
      <TRNAMT>60.00</TRNAMT>
      <DTPOSTED>202604101230</DTPOSTED>
      <NAME>DATE AND TIME NO SECS</NAME>
      </STMTTRN>
      """

      transactions = OFXParser.parse(content, :standard)
      assert length(transactions) == 2

      t1 = Enum.at(transactions, 0)
      assert t1.description == "ONLY DATE"
      assert t1.date == ~D[2026-04-10]
      assert t1.time == nil

      t2 = Enum.at(transactions, 1)
      assert t2.description == "DATE AND TIME NO SECS"
      assert t2.date == ~D[2026-04-10]
      assert t2.time == ~T[12:30:00]
    end

    test "handles missing mandatory tags" do
      content = """
      <STMTTRN>
      <NAME>MISSING STUFF</NAME>
      </STMTTRN>
      """

      # This will result in parse_decimal(nil) and parse_ofx_date(nil)
      assert OFXParser.parse(content, :standard) == []
    end

    test "handles invalid integers in date components" do
      content = """
      <STMTTRN>
      <TRNAMT>10.00</TRNAMT>
      <DTPOSTED>2026XX10</DTPOSTED>
      <NAME>BAD DATE</NAME>
      </STMTTRN>
      """

      assert OFXParser.parse(content, :standard) == []
    end
  end
end
