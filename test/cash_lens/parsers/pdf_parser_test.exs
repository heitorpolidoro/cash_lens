defmodule CashLens.PDFParserTest do
  use CashLens.DataCase, async: true
  alias CashLens.Parsers.PDFParser

  describe "parse/2 (sem_parar)" do
    test "correctly parses Sem Parar monthly fee" do
      text = """
      Extrato Mensal de Utilização
      Plano Contratado: SEM PARAR 10/12/25 R$ 58,17
      """

      transactions = PDFParser.parse(text, :sem_parar)

      assert length(transactions) == 1
      tx = List.first(transactions)
      assert tx.description == "Mensalidade Sem Parar"
      assert tx.amount == Decimal.new("-58.17")
      assert tx.date == ~D[2025-12-10]
    end

    test "correctly parses usage transactions with multi-line description" do
      text = """
      ABC1D23                                      26/11/25         RIOSP                                                             R$ 7,70
                                                   às 19:38:12      JACAREI SUL, CAT. 1
      XYZ9G88                                      27/11/25         ESTAPAR                                                           R$ 15,00
                                                   às 10:15:00      SHOPPING MORUMBI
      """

      transactions = PDFParser.parse(text, :sem_parar)

      assert length(transactions) == 2

      t1 = Enum.find(transactions, fn t -> String.contains?(t.description, "JACAREI") end)
      assert t1.amount == Decimal.new("-7.70")
      assert t1.date == ~D[2025-11-26]
      assert t1.time == ~T[19:38:12]
      assert String.contains?(t1.description, "RIOSP JACAREI SUL")

      t2 = Enum.find(transactions, fn t -> String.contains?(t.description, "SHOPPING") end)
      assert t2.amount == Decimal.new("-15.00")
      assert t2.date == ~D[2025-11-27]
      assert t2.time == ~T[10:15:00]
    end

    test "parses both fee and usage in the same text" do
      text = """
      Plano Contratado: SEM PARAR 01/01/26 R$ 60,00
      ABC1D23 02/01/26 TOLL R$ 5,50
              às 08:00:00 MAIN GATE
      """

      transactions = PDFParser.parse(text, :sem_parar)
      assert length(transactions) == 2
    end

    test "handles usage line without a following time line" do
      text = """
      XYZ9G88 27/11/25 ESTAPAR R$ 15,00
      Some other random text that doesn't match
      """

      transactions = PDFParser.parse(text, :sem_parar)
      
      assert length(transactions) == 1
      tx = List.first(transactions)
      assert tx.description == "ESTAPAR"
      assert tx.amount == Decimal.new("-15.00")
    end
  end
end
