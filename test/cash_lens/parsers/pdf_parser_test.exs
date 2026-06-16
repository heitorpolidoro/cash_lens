defmodule CashLens.PDFParserTest do
  use CashLens.DataCase, async: false
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

    test "handles malformed data in internal helpers" do
      text = """
      Plano Contratado 01/01/26 R$ 1,2,3
      ABC1D23 INVALID_DATE DESCRIPTION R$ 10,00
      ABC1D23 02/01/26 DESCRIPTION R$ 10,00
              às INVALID_TIME EXTRA
      """

      transactions = PDFParser.parse(text, :sem_parar)
      assert transactions != []

      # The fee with "1,2,3" amount should result in Decimal 0 after parse_amount
      fee = Enum.find(transactions, &(&1.description == "Mensalidade Sem Parar"))
      assert fee.amount == Decimal.new("0")

      # The usage with INVALID_DATE should fallback to Date.utc_today()
      # (Because it matches \S+ and then parse_date hits the fallback)
      usage1 = Enum.find(transactions, &(&1.description == "DESCRIPTION"))
      assert usage1.date == Date.utc_today()

      # The usage with INVALID_TIME should fallback to nil time
      # Note: with loosened regex, "INVALID_TIME" matches \S+ in regex_l2
      usage2 = Enum.find(transactions, &(&1.description == "DESCRIPTION EXTRA"))
      assert usage2.time == nil
    end

    test "handles malformed amount in plan fee" do
      text = "Plano Contratado: 01/01/26 R$ 1,2,3"
      [tx] = PDFParser.parse(text, :sem_parar)
      assert tx.amount == Decimal.new("0")
    end

    test "handles nil and empty inputs gracefully" do
      assert PDFParser.parse("", :sem_parar) == []
      # Triggering parse_amount(nil) if possible via malformed usage
      # ABC1D23 02/01/26 DESCRIPTION R$ (missing amount)
      text = "ABC1D23 02/01/26 DESCRIPTION R$ \n"
      assert PDFParser.parse(text, :sem_parar) == []
    end

    test "parse_time handles invalid time parts" do
      # Triggers the else -> nil in parse_time
      # This matches the regex às HH:MM:SS but Integer.parse fails
      text = "01/01/26 DESCRIPTION R$ 10,00\n às XX:YY:ZZ EXTRA"
      results = PDFParser.parse(text, :sem_parar)
      assert List.first(results).time == nil
    end

    test "do_parse_date falls back to today for invalid date components" do
      # "31/13/26" splits into 3 parts so do_parse_date is called,
      # but month 13 is invalid → Date.new fails → fallback to Date.utc_today()
      text = "Plano Contratado: 31/13/26 R$ 10,00"
      [tx] = PDFParser.parse(text, :sem_parar)
      assert tx.date == Date.utc_today()
    end
  end

  describe "parse/2 (bradesco_card)" do
    test "correctly parses Amazon Mastercard statement text" do
      text = """
      Fatura mensal
      HEITOR POLIDORO
      AMAZON MASTERCARD PLATINUM 5373.63**.****.8015

      Total da fatura                                                                Vencimento
      R$ 56,53                                                                       10/03/2026

      Lançamentos
      Data Descrição                                                        Valor R$
      Nacionais em Reais (R$)
      HEITOR POLIDORO                                            5373.63**.****.8015
      28/01    AMAZON BR            SAO PAULO      BRA                           0,34        Demais faturas                                                             R$ 0,00
      28/01    AMAZON BR            SAO PAULO      BRA                          52,15
      01/02    IOF DIARIO                                                        0,01

      Total da fatura em real                                                          56,53
      """

      transactions = PDFParser.parse(text, :bradesco_card)

      assert length(transactions) == 3
      [t1, t2, t3] = transactions

      assert t1.description == "AMAZON BR SAO PAULO BRA"
      assert t1.amount == Decimal.new("-0.34")
      assert t1.date == ~D[2026-01-28]

      assert t2.description == "AMAZON BR SAO PAULO BRA"
      assert t2.amount == Decimal.new("-52.15")
      assert t2.date == ~D[2026-01-28]

      assert t3.description == "IOF DIARIO"
      assert t3.amount == Decimal.new("-0.01")
      assert t3.date == ~D[2026-02-01]
    end

    test "correctly parses small statement without Lançamentos header and with wrapped description" do
      text = """
      Aplicativo Bradesco Cartões
      Data: 01/06/2026 - 08:46

      Situação do Extrato: FECHADO

      HEITOR POLIDORO - AMAZON MASTERCARD PLATINUM          XXXX.XXXX.XXXX.8015

                                              Moeda de              Cotação
       Data    Histórico                                 US$                      R$
                                              origem                   US$

       -       SALDO ANTERIOR                                                 166,47

       27/01   JUROS DE MORA DE ATRASO                                           0,06

               PAGAMENTO RECEBIDO -
       13/01                                                                  -166,47
               OBRI

               MULTA CONTRATUAL DE
       12/01                                                                     3,34
               ATRAS

               Total para HEITOR                                                  R$
      """

      transactions = PDFParser.parse(text, :bradesco_card)

      assert length(transactions) == 3
      [t1, t2, t3] = transactions

      assert t1.description == "JUROS DE MORA DE ATRASO"
      assert t1.amount == Decimal.new("-0.06")
      assert t1.date == ~D[2026-01-27]

      assert t2.description == "PAGAMENTO RECEBIDO - OBRI"
      assert t2.amount == Decimal.new("166.47")
      assert t2.date == ~D[2026-01-13]

      assert t3.description == "MULTA CONTRATUAL DE ATRAS"
      assert t3.amount == Decimal.new("-3.34")
      assert t3.date == ~D[2026-01-12]
    end

    test "correctly parses Amex statement text" do
      text = """
      Fatura Mensal
      AMEX GOLD CARD PRIME
      Total da fatura                 Vencimento
      R$ 1.099,28                  10/05/2026

      Número do Cartão                      3747 XXXXXX 58225
      Lançamentos

      Data Histórico de Lançamentos               Cidade         US$
      HEITOR LUIS POLIDORO                         Cartão 3747 XXXXXX 58225
      11/04 CINEMARK COLINAS                      SAO JOSE DOS                           232,00       Compras                          R$ 1.239,08
      27/04 SEGURO SUPERPROTEGIDO                                                           9,99       Rotativo                 14,99% 434,46% 481,28%               16,99%

       Total para HEITOR LUIS POLIDORO                                                 1.099,28
      """

      transactions = PDFParser.parse(text, :bradesco_card)

      assert length(transactions) == 2
      [t1, t2] = transactions

      assert t1.description == "CINEMARK COLINAS SAO JOSE DOS"
      assert t1.amount == Decimal.new("-232.00")
      assert t1.date == ~D[2026-04-11]

      assert t2.description == "SEGURO SUPERPROTEGIDO"
      assert t2.amount == Decimal.new("-9.99")
      assert t2.date == ~D[2026-04-27]
    end

    test "correctly handles year boundary on December purchases" do
      text = """
      Fatura mensal
      Vencimento
      10/01/2026

      Lançamentos
      28/12    SOME PURCHASE                                                       100,00
      02/01    OTHER PURCHASE                                                       50,00
      Total para HEITOR POLIDORO
      """

      transactions = PDFParser.parse(text, :bradesco_card)
      assert length(transactions) == 2
      [t1, t2] = transactions

      assert t1.description == "SOME PURCHASE"
      assert t1.amount == Decimal.new("-100.00")
      assert t1.date == ~D[2025-12-28]

      assert t2.description == "OTHER PURCHASE"
      assert t2.amount == Decimal.new("-50.00")
      assert t2.date == ~D[2026-01-02]
    end

    test "correctly parses 2026-01-Amazon statement layout" do
      text = """
                                                                                                                                                                                                                                            10/01/2026
      Lançamentos
      09/12    AmazonPrimeBR          SAO PAULO      BRA                       166,80        Demais faturas                                                             R$ 0,00
      """

      transactions = PDFParser.parse(text, :bradesco_card)

      assert length(transactions) == 1
      tx = List.first(transactions)
      assert tx.description == "AmazonPrimeBR SAO PAULO BRA"
      assert tx.amount == Decimal.new("-166.80")
      assert tx.date == ~D[2025-12-09]
    end
  end
end
