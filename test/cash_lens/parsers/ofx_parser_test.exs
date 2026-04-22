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
  end
end
