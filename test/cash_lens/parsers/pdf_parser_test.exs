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

  describe "parse/2 (mercado_pago_card)" do
    test "parses the payment line, every purchase row, and normalizes Parcela to PARC N/M" do
      # Real fatura text (pdftotext -layout output), trimmed to the
      # "Detalhes de consumo" section onward — the marketing/informational
      # pages before and after it don't affect parsing and are omitted.
      text = """
      Detalhes de consumo

      Movimentações na fatura

      Data      Movimentações                                            Valor em R$


      17/06     Pagamento da fatura de junho/2026                         R$ 1.412,10



      Cartão Visa [************8978]

      Data      Movimentações                                            Valor em R$


      27/02     MERCADOLIVRE*7PRODUTOS              Parcela 5 de 7         R$ 22,65


      02/04     MERCADOLIVRE*26PRODUTOS             Parcela 9 de 12        R$ 42,44


      22/04     MERCADOLIVRE*4PRODUTOS               Parcela 3 de 7         R$ 22,14


      24/04     MERCADOLIVRE*3PRODUTOS              Parcela 3 de 10         R$ 41,29


      29/04     MERCADOLIVRE*MERCADOLIVRE           Parcela 3 de 5          R$ 13,44


      12/05     MERCADOLIVRE*MCUTILIDADES           Parcela 2 de 4          R$ 8,40


      02/06     MERCADOLIVRE*MERCADOLI              Parcela 2 de 5          R$ 15,56


      02/06     MERCADOLIVRE*MERCADOLI              Parcela 2 de 8         R$ 42,57


      06/06     MERCADOLIVRE*MASTERREMOTE           Parcela 2 de 6          R$ 19,99


      16/06     MERCADOLIVRE*MERCADOLIVRE                                   R$ 76,75


      21/06     MERCADOLIVRE*MERCADOLIVRE           Parcela 1 de 12        R$ 48,50


      21/06     MERCADOLIVRE*MERCADOLIVRE                                  R$ 301,67


      25/06     MERCADOLIVRE*MERCADOLI                                    R$ 402,60
                                               Heitor Luis Polidoro
                                            Vencimento: 17/07/2026


      Cartão Visa [************8978]

      Data      Movimentações                          Valor em R$


      25/06     MERCADOLIVRE*MERCADOLIVRE                R$ 201,41


      06/07     MERCADOLIVRE*MERCADOLI                   R$ 98,54

      Total                                             R$ 1.357,95
      """

      transactions = PDFParser.parse(text, :mercado_pago_card)

      assert length(transactions) == 16

      payment = Enum.find(transactions, &(&1.description =~ "Pagamento da fatura"))
      assert payment.description == "Pagamento da fatura de junho/2026"
      assert payment.amount == Decimal.new("1412.10")
      assert payment.date == ~D[2026-06-17]

      installment = Enum.find(transactions, &(&1.description =~ "7PRODUTOS"))
      assert installment.description == "MERCADOLIVRE*7PRODUTOS PARC 5/7"
      assert installment.amount == Decimal.new("-22.65")
      assert installment.date == ~D[2026-02-27]

      plain = Enum.find(transactions, &(&1.amount == Decimal.new("-76.75")))
      assert plain.description == "MERCADOLIVRE*MERCADOLIVRE"
      assert plain.date == ~D[2026-06-16]

      # Row from the page-3 continuation of the same "Cartão Visa" table —
      # proves the section-tracking survives the repeated page header.
      continuation = Enum.find(transactions, &(&1.amount == Decimal.new("-201.41")))
      assert continuation.description == "MERCADOLIVRE*MERCADOLIVRE"
      assert continuation.date == ~D[2026-06-25]

      purchases_total =
        transactions
        |> Enum.reject(&(&1.description =~ "Pagamento da fatura"))
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))

      assert Decimal.equal?(purchases_total, Decimal.new("-1357.95"))
    end

    test "a row with no Parcela column keeps its description unsuffixed" do
      text = """
      Movimentações na fatura

      Cartão Visa [****1234]
      Data      Movimentações                          Valor em R$
      01/03     LOJA SEM PARCELA                        R$ 10,00
      """

      [tx] = PDFParser.parse(text, :mercado_pago_card)
      assert tx.description == "LOJA SEM PARCELA"
      # Note: can't assert `refute tx.description =~ "PARC"` here — the
      # fixture description "LOJA SEM PARCELA" itself contains the substring
      # "PARC" (from "PARCELA"), so that assertion would always fail
      # regardless of parser correctness. Assert on the actual suffix our
      # code would append instead.
      refute tx.description =~ ~r/ PARC \d+\/\d+/
    end
  end

  describe "extract_statement_meta/1" do
    test "extract_statement_meta pulls due date, total and competencia" do
      text = """
      Vencimento 15/06/2026
      01/06 UBER TRIP 27,90
      TOTAL DA FATURA EM REAL 3.812,40
      """

      meta = PDFParser.extract_statement_meta(text)
      assert meta.due_date == ~D[2026-06-15]
      assert Decimal.equal?(meta.total_a_pagar, Decimal.new("3812.40"))
      assert meta.competencia == ~D[2026-06-01]
    end

    test "extract_statement_meta finds Vencimento when the date is separated from the label" do
      # Real Bradesco card layout: the "Vencimento" label and its date sit on
      # different lines with other content (the total) between them.
      text = """
      Total da fatura                                          Vencimento
      R$ 56,53                                                 10/03/2026

      Total da fatura em real                                  56,53
      """

      meta = PDFParser.extract_statement_meta(text)
      assert meta.due_date == ~D[2026-03-10]
      assert meta.competencia == ~D[2026-03-01]
      assert Decimal.equal?(meta.total_a_pagar, Decimal.new("56.53"))
    end

    test "extract_statement_meta degrades to nils when absent" do
      meta = PDFParser.extract_statement_meta("no relevant lines")
      assert meta.due_date == nil
      assert meta.total_a_pagar == nil
    end

    test "extract_statement_meta on a Mercado Pago fatura ignores the decoy previous-cycle total" do
      # Real fatura text (pdftotext -layout output): note "Total da fatura de
      # junho" (a DIFFERENT, previous-cycle number) appears before the real
      # total — this must not be picked up.
      text = """
      Olá, Heitor Luis
      Essa é sua fatura de julho
      Total a pagar                            Vence em                      Limite total                 Saque total
                                               17/07/2026                    R$ 23.200,00                 R$ 50,00
      R$ 1.357,95

      Informações complementares
      Resumo da fatura

        Consumos de 13/06 a 12/07                               R$ 1.357,95                Juros do mês anterior                                           R$ 0,00

        Tarifas e encargos                                           R$ 0,00               Pagamentos e créditos devolvidos                            R$ 1.412,10

        Multas por atraso                                            R$ 0,00

        Total da fatura de junho                                 R$ 1.412,10


                                                                                            Total                                         R$ 1.357,95

      Heitor Luis Polidoro
      Vencimento: 17/07/2026
      """

      meta = PDFParser.extract_statement_meta(text)

      assert meta.due_date == ~D[2026-07-17]
      assert meta.competencia == ~D[2026-07-01]
      assert Decimal.equal?(meta.total_a_pagar, Decimal.new("1357.95"))
    end
  end
end
